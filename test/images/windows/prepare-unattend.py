#!/usr/bin/env python3
"""Render the imported Windows answer file with private bake-time values."""

from __future__ import annotations

import argparse
import base64
import os
from pathlib import Path
import xml.etree.ElementTree as ET

UNATTEND_NS = "urn:schemas-microsoft-com:unattend"
WCM_NS = "http://schemas.microsoft.com/WMIConfig/2002/State"
ET.register_namespace("", UNATTEND_NS)
ET.register_namespace("wcm", WCM_NS)


def tag(name: str) -> str:
    return f"{{{UNATTEND_NS}}}{name}"


def add_action(parent: ET.Element, name: str) -> ET.Element:
    return ET.SubElement(parent, tag(name), {f"{{{WCM_NS}}}action": "add"})


def child(parent: ET.Element, name: str) -> ET.Element:
    found = parent.find(tag(name))
    return found if found is not None else ET.SubElement(parent, tag(name))


def set_text(parent: ET.Element, name: str, value: str) -> None:
    child(parent, name).text = value


def component(root: ET.Element, pass_name: str, component_name: str) -> ET.Element:
    settings = root.find(f"{tag('settings')}[@pass='{pass_name}']")
    if settings is None:
        settings = ET.SubElement(root, tag("settings"), {"pass": pass_name})
    for candidate in settings.findall(tag("component")):
        if candidate.get("name") == component_name:
            return candidate
    return ET.SubElement(
        settings,
        tag("component"),
        {
            "name": component_name,
            "processorArchitecture": "amd64",
            "publicKeyToken": "31bf3856ad364e35",
            "language": "neutral",
            "versionScope": "nonSxS",
        },
    )


def add_disk_and_image_selection(setup: ET.Element, image_name: str) -> None:
    disk_configuration = child(setup, "DiskConfiguration")
    disk_configuration.clear()
    disk = add_action(disk_configuration, "Disk")
    set_text(disk, "DiskID", "0")
    set_text(disk, "WillWipeDisk", "true")
    create = child(disk, "CreatePartitions")
    for order, size, kind in ((1, "300", "EFI"), (2, "16", "MSR"), (3, None, "Primary")):
        part = add_action(create, "CreatePartition")
        set_text(part, "Order", str(order))
        set_text(part, "Type", kind)
        if size is not None:
            set_text(part, "Size", size)
        else:
            set_text(part, "Extend", "true")

    modify = child(disk, "ModifyPartitions")
    # Canonical element order from Microsoft's ModifyPartition example:
    # Order, PartitionID, Label, [Letter], Format. (The MSR partition must not
    # be modified.)
    for order, partition_id, fmt, label, letter in (
        (1, 1, "FAT32", "System", None),
        (2, 3, "NTFS", "Windows", "C"),
    ):
        part = add_action(modify, "ModifyPartition")
        set_text(part, "Order", str(order))
        set_text(part, "PartitionID", str(partition_id))
        set_text(part, "Label", label)
        if letter:
            set_text(part, "Letter", letter)
        set_text(part, "Format", fmt)
    set_text(disk, "WillShowUI", "OnError")

    image_install = child(setup, "ImageInstall")
    image_install.clear()
    os_image = child(image_install, "OSImage")
    install_from = child(os_image, "InstallFrom")
    metadata = add_action(install_from, "MetaData")
    set_text(metadata, "Key", "/IMAGE/NAME")
    set_text(metadata, "Value", image_name)
    install_to = child(os_image, "InstallTo")
    set_text(install_to, "DiskID", "0")
    set_text(install_to, "PartitionID", "3")
    set_text(os_image, "WillShowUI", "OnError")

    # Keep the Windows Setup answer-file order canonical. Existing UserData,
    # UseConfigurationSet, and RunSynchronous content is preserved.
    ordered_names = ("DiskConfiguration", "ImageInstall", "UserData")
    existing = list(setup)
    ordered = [setup.find(tag(name)) for name in ordered_names]
    ordered = [item for item in ordered if item is not None]
    ordered.extend(item for item in existing if item not in ordered)
    setup[:] = ordered


def add_user_and_first_logon(root: ET.Element, password: str) -> int:
    shell = component(root, "oobeSystem", "Microsoft-Windows-Shell-Setup")
    user_accounts = child(shell, "UserAccounts")
    local_accounts = child(user_accounts, "LocalAccounts")
    for account in list(local_accounts.findall(tag("LocalAccount"))):
        if account.findtext(tag("Name")) == "provision":
            local_accounts.remove(account)
    account = add_action(local_accounts, "LocalAccount")
    set_text(account, "Description", "Dotfiles test VM administrator")
    set_text(account, "DisplayName", "Provision")
    set_text(account, "Group", "Administrators")
    set_text(account, "Name", "provision")
    password_node = child(account, "Password")
    set_text(password_node, "Value", password)
    set_text(password_node, "PlainText", "true")

    # LogonCount must be high (not 1): the OOBE first logon consumes one count,
    # so a LogonCount of 1 leaves every later boot of the golden with no
    # interactive console session — AppXSVC then fails Store-MSIX installs
    # (0x80073d19 "user was disconnected") from headless/SSH sessions.
    autologon = child(shell, "AutoLogon")
    set_text(autologon, "Enabled", "true")
    set_text(autologon, "LogonCount", "9999")
    set_text(autologon, "Username", "provision")
    set_text(autologon, "Domain", ".")
    auto_password = child(autologon, "Password")
    set_text(auto_password, "Value", password)
    set_text(auto_password, "PlainText", "true")

    first_logon = child(shell, "FirstLogonCommands")
    commands = first_logon.findall(tag("SynchronousCommand"))
    max_order = max(
        (int(command.findtext(tag("Order"), "0")) for command in commands),
        default=0,
    )

    # Setup mounts the FAT32 media by its volume label; no drive-letter guess.
    script = (
        "$ErrorActionPreference='Stop'; "
        "$media=Get-CimInstance Win32_LogicalDisk | "
        "Where-Object {$_.VolumeName -eq 'DOTFILES'} | Select-Object -First 1; "
        "if(-not $media){throw 'DOTFILES provisioning media was not found'}; "
        "& ($media.DeviceID + '\\provision.ps1')"
    )
    encoded = base64.b64encode(script.encode("utf-16le")).decode("ascii")
    command = add_action(first_logon, "SynchronousCommand")
    set_text(command, "Order", str(max_order + 1))
    set_text(command, "Description", "Configure test VM and enable SSH")
    set_text(
        command,
        "CommandLine",
        f"powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand {encoded}",
    )
    # FirstLogonCommands' SynchronousCommand does NOT support WillReboot (that
    # belongs to RunSynchronousCommand). Including it makes oobeldr reject the
    # answer file ("setting not defined in this component") and OOBE fails with
    # "Windows could not complete the installation".

    shell_order = ("OOBE", "UserAccounts", "AutoLogon", "FirstLogonCommands")
    existing_shell = list(shell)
    ordered_shell = [shell.find(tag(name)) for name in shell_order]
    ordered_shell = [item for item in ordered_shell if item is not None]
    ordered_shell.extend(item for item in existing_shell if item not in ordered_shell)
    shell[:] = ordered_shell
    return max_order + 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--password-file", type=Path, required=True)
    parser.add_argument("--public-key-file", type=Path, required=True)
    parser.add_argument("--provision-template", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument(
        "--image-name", default=os.environ.get("DOTFILES_TEST_WINDOWS_IMAGE_NAME", "Windows 11 Pro")
    )
    args = parser.parse_args()

    password = args.password_file.read_text(encoding="utf-8").rstrip("\r\n")
    if not password or "\n" in password or "\r" in password:
        raise SystemExit("the Windows become-password file must contain one non-empty line")
    public_key = args.public_key_file.read_text(encoding="utf-8").strip()
    if not public_key.startswith(("ssh-ed25519 ", "ssh-rsa ", "ecdsa-sha2-")):
        raise SystemExit("the harness public key is missing or has an unsupported format")

    args.out_dir.mkdir(parents=True, exist_ok=True)
    root = ET.parse(args.source).getroot()
    setup = component(root, "windowsPE", "Microsoft-Windows-Setup")
    add_disk_and_image_selection(setup, args.image_name)

    user_data = child(setup, "UserData")
    set_text(user_data, "AcceptEula", "true")
    product_key = child(user_data, "ProductKey")
    set_text(product_key, "Key", "")
    set_text(product_key, "WillShowUI", "Never")
    user_data_order = ("AcceptEula", "FullName", "Organization", "ProductKey")
    current_user_data = list(user_data)
    ordered_user_data = [user_data.find(tag(name)) for name in user_data_order]
    ordered_user_data = [item for item in ordered_user_data if item is not None]
    ordered_user_data.extend(item for item in current_user_data if item not in ordered_user_data)
    user_data[:] = ordered_user_data

    shell = component(root, "oobeSystem", "Microsoft-Windows-Shell-Setup")
    oobe = child(shell, "OOBE")
    set_text(oobe, "HideEULAPage", "true")
    set_text(oobe, "HideLocalAccountScreen", "true")
    set_text(oobe, "HideOnlineAccountScreens", "true")
    set_text(oobe, "HideWirelessSetupInOOBE", "true")
    set_text(oobe, "ProtectYourPC", "3")
    # Do not set SkipMachineOOBE/SkipUserOOBE: they are deprecated and cause
    # "Windows could not complete the installation" on Windows 11. The local
    # account + AutoLogon below are what make OOBE unattended.
    order = add_user_and_first_logon(root, password)

    xml_path = args.out_dir / "autounattend.xml"
    ET.indent(root, space="  ")
    ET.ElementTree(root).write(xml_path, encoding="utf-8", xml_declaration=True)
    xml_path.chmod(0o600)

    provision = args.provision_template.read_text(encoding="utf-8")
    provision = provision.replace("@@HARNESS_PUBLIC_KEY@@", public_key.replace("'", "''"))
    provision_path = args.out_dir / "provision.ps1"
    provision_path.write_text(provision, encoding="utf-8", newline="\r\n")
    provision_path.chmod(0o600)
    print(f"Rendered answer file for image '{args.image_name}'; appended FirstLogonCommands Order {order}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
