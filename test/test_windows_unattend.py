#!/usr/bin/env python3
"""Regression checks for the Windows unattended-answer-file renderer."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

REPO = Path(__file__).resolve().parents[1]
SOURCE = REPO / "test/images/windows/autounattend/autounattend.xml"
RENDERER = REPO / "test/images/windows/prepare-unattend.py"
PROVISION = REPO / "test/images/windows/autounattend/provision.ps1"
NS = {"u": "urn:schemas-microsoft-com:unattend"}


class PrepareUnattendTests(unittest.TestCase):
    def test_adds_unattended_setup_without_losing_existing_commands(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            password_file = root / "password"
            password_file.write_text("temporary-test-password\n", encoding="utf-8")
            password_file.chmod(0o600)
            key_file = root / "id_ed25519.pub"
            key_file.write_text("ssh-ed25519 AAAATESTKEY test\n", encoding="utf-8")
            output = root / "rendered"

            subprocess.run(
                [
                    "python3",
                    str(RENDERER),
                    "--source",
                    str(SOURCE),
                    "--password-file",
                    str(password_file),
                    "--public-key-file",
                    str(key_file),
                    "--provision-template",
                    str(PROVISION),
                    "--out-dir",
                    str(output),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            rendered = ET.parse(output / "autounattend.xml").getroot()
            setup = rendered.find(
                "u:settings[@pass='windowsPE']/u:component[@name='Microsoft-Windows-Setup']",
                NS,
            )
            self.assertIsNotNone(setup)
            self.assertEqual(
                [node.tag.rsplit("}", 1)[-1] for node in setup],
                ["DiskConfiguration", "ImageInstall", "UserData", "UseConfigurationSet", "RunSynchronous"],
            )
            self.assertEqual(
                setup.findtext("u:ImageInstall/u:OSImage/u:InstallFrom/u:MetaData/u:Value", namespaces=NS),
                "Windows 11 Pro",
            )
            disk = setup.find("u:DiskConfiguration/u:Disk", NS)
            self.assertEqual(disk.findtext("u:DiskID", namespaces=NS), "0")
            self.assertTrue(disk.attrib)
            product_key = setup.find("u:UserData/u:ProductKey", NS)
            self.assertEqual(product_key.findtext("u:Key", namespaces=NS), "")
            self.assertEqual(product_key.findtext("u:WillShowUI", namespaces=NS), "Never")

            original_count = len(
                ET.parse(SOURCE).getroot().findall(
                    ".//u:settings[@pass='windowsPE']/u:component[@name='Microsoft-Windows-Setup']/u:RunSynchronous/u:RunSynchronousCommand",
                    NS,
                )
            )
            self.assertEqual(
                len(setup.findall("u:RunSynchronous/u:RunSynchronousCommand", NS)),
                original_count,
            )

            shell = rendered.find(
                "u:settings[@pass='oobeSystem']/u:component[@name='Microsoft-Windows-Shell-Setup']",
                NS,
            )
            self.assertIsNotNone(shell)
            self.assertEqual(
                [node.tag.rsplit("}", 1)[-1] for node in shell][:4],
                ["OOBE", "UserAccounts", "AutoLogon", "FirstLogonCommands"],
            )
            # Deprecated OOBE skips break Windows 11 OOBE ("Windows could not
            # complete the installation"), so the renderer must never emit them.
            for deprecated in ("SkipMachineOOBE", "SkipUserOOBE"):
                self.assertIsNone(
                    shell.find(f"u:OOBE/u:{deprecated}", NS),
                    f"{deprecated} must not be set",
                )
            account = shell.find("u:UserAccounts/u:LocalAccounts/u:LocalAccount", NS)
            self.assertEqual(account.findtext("u:Name", namespaces=NS), "provision")
            self.assertEqual(account.findtext("u:Password/u:Value", namespaces=NS), "temporary-test-password")
            # AutoLogon must stay enabled with a high LogonCount: the OOBE
            # first logon consumes one count, so LogonCount=1 leaves every
            # later boot of the golden without an interactive console session
            # (Store-MSIX installs then fail 0x80073d19 from SSH sessions).
            autologon = shell.find("u:AutoLogon", NS)
            self.assertEqual(autologon.findtext("u:Enabled", namespaces=NS), "true")
            self.assertGreater(
                int(autologon.findtext("u:LogonCount", namespaces=NS)),
                1,
                "LogonCount must exceed the single OOBE logon so later boots autologon",
            )
            commands = shell.findall("u:FirstLogonCommands/u:SynchronousCommand", NS)
            self.assertEqual([int(c.findtext("u:Order", namespaces=NS)) for c in commands], [1, 2])
            self.assertIn("EncodedCommand", commands[-1].findtext("u:CommandLine", namespaces=NS))
            # FirstLogonCommands' SynchronousCommand only accepts these children;
            # WillReboot (valid for RunSynchronousCommand) makes OOBE fail.
            allowed = {"CommandLine", "Description", "Order", "RequiresUserInput"}
            for command in commands:
                names = {node.tag.rsplit("}", 1)[-1] for node in command}
                self.assertLessEqual(names, allowed, f"invalid FirstLogon child: {names - allowed}")
            self.assertEqual(os.stat(output / "autounattend.xml").st_mode & 0o777, 0o600)
            self.assertIn("ssh-ed25519 AAAATESTKEY test", (output / "provision.ps1").read_text())

            # The tracked source deliberately contains neither the password nor
            # the generic/product key; those belong only in ignored build media.
            self.assertNotIn("temporary-test-password", SOURCE.read_text())
            self.assertNotIn("VK7JG-NPHTM-C97JM-9MPGT-3V66T", SOURCE.read_text())


if __name__ == "__main__":
    unittest.main()
