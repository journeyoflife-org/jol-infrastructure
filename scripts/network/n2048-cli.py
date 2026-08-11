#!/usr/bin/env python3
"""Dell N2048 switch management helper using pexpect over SSH.

Usage:
    python3 scripts/network/n2048-cli.py --commands "show running-config" "show vlan"
    python3 scripts/network/n2048-cli.py "show running-config" "show vlan"
    python3 scripts/network/n2048-cli.py --config "interface gigabitethernet 1/0/4" shutdown "no shutdown" exit
    python3 scripts/network/n2048-cli.py --file commands.txt
    python3 scripts/network/n2048-cli.py --interactive
"""

import argparse
import os
import sys
import time

import pexpect

SWITCH_HOST = os.environ.get("N2048_HOST", "10.10.10.2")
SWITCH_USER = os.environ.get("N2048_USER", "admin")
SWITCH_PASS = os.environ.get("N2048_PASS", "")
TIMEOUT = 30

if not SWITCH_PASS:
    import getpass
    SWITCH_PASS = getpass.getpass(f"Switch password for {SWITCH_USER}@{SWITCH_HOST}: ")


def connect():
    """Establish SSH connection to the Dell N2048."""
    cmd = (
        f"ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        f"-o ConnectTimeout=10 {SWITCH_USER}@{SWITCH_HOST}"
    )
    child = pexpect.spawn(cmd, encoding="utf-8", timeout=TIMEOUT)
    idx = child.expect(["[Pp]assword:", pexpect.TIMEOUT, pexpect.EOF])
    if idx != 0:
        print("ERROR: Did not receive password prompt", file=sys.stderr)
        sys.exit(1)
    child.sendline(SWITCH_PASS)
    # Wait for the switch prompt (e.g., "console>" or "console#")
    idx = child.expect([r"[>#]", "[Pp]assword:", pexpect.TIMEOUT])
    if idx == 1:
        print("ERROR: Authentication failed (bad password)", file=sys.stderr)
        sys.exit(1)
    if idx == 2:
        print("ERROR: Timed out waiting for switch prompt", file=sys.stderr)
        sys.exit(1)
    return child


def send_command(child, command, wait=2):
    """Send a command and capture output, handling --More-- and '^' pager."""
    child.sendline(command)
    time.sleep(wait)
    output_parts = []
    while True:
        idx = child.expect([r"[>#]", r"--More--", r"\^", pexpect.TIMEOUT], timeout=15)
        output_parts.append(child.before)
        if idx == 0:
            # Got the prompt — done
            break
        elif idx == 1:
            # Pager — send space to continue
            child.send(" ")
            time.sleep(1)
        elif idx == 2:
            # Dell CLI pager interrupt (appears on long output, e.g. show
            # logging). Consume the trailing error banner, treat as complete.
            child.expect([r"[>#]", pexpect.TIMEOUT], timeout=5)
            break
        else:
            # Timeout — assume done
            break
    output = "".join(output_parts)
    # Clean up: remove the echoed command from output
    lines = output.splitlines()
    if lines and command in lines[0]:
        lines = lines[1:]
    return "\n".join(lines).strip()


def enter_enable(child):
    """Enter enable mode if not already there."""
    child.sendline("enable")
    time.sleep(1)
    idx = child.expect([r"[Pp]assword:", r"#", pexpect.TIMEOUT])
    if idx == 0:
        # Enable password (often same as login or empty)
        child.sendline(SWITCH_PASS)
        child.expect([r"#", pexpect.TIMEOUT])
    # Disable pager for long outputs
    child.sendline("terminal length 0")
    time.sleep(0.5)
    child.expect([r"#", pexpect.TIMEOUT])
    return child


def enter_config(child):
    """Enter configure mode."""
    child.sendline("configure")
    time.sleep(1)
    child.expect([r"\(config\)#", pexpect.TIMEOUT])
    return child


def run_show_commands(commands):
    """Run read-only show commands and return output."""
    child = connect()
    child = enter_enable(child)
    results = []
    for cmd in commands:
        print(f"\n{'='*60}")
        print(f"COMMAND: {cmd}")
        print(f"{'='*60}")
        output = send_command(child, cmd, wait=3)
        print(output)
        results.append(f"COMMAND: {cmd}\n{output}")
    child.sendline("exit")
    child.close()
    return "\n\n".join(results)


def run_config_commands(commands):
    """Enter config mode and apply configuration commands."""
    child = connect()
    child = enter_enable(child)
    child = enter_config(child)
    results = []
    for cmd in commands:
        print(f"  > {cmd}")
        child.sendline(cmd)
        time.sleep(0.5)
        # Check for errors
        idx = child.expect([r"\(config[^)]*\)#", "%", pexpect.TIMEOUT], timeout=10)
        if idx == 1:
            error_msg = child.before + child.after
            child.expect([r"\(config[^)]*\)#", pexpect.TIMEOUT])
            error_msg += child.before
            print(f"    ERROR: {error_msg.strip()}")
            results.append(f"ERROR: {cmd} -> {error_msg.strip()}")
        elif idx == 2:
            print(f"    TIMEOUT waiting for prompt")
            results.append(f"TIMEOUT: {cmd}")
        else:
            results.append(f"OK: {cmd}")
    # Exit config mode
    child.sendline("exit")
    time.sleep(1)
    child.expect([r"#", pexpect.TIMEOUT])
    child.sendline("exit")
    child.close()
    return results


def main():
    parser = argparse.ArgumentParser(description="Dell N2048 CLI helper")
    parser.add_argument("positional_commands", nargs="*",
                        help="Commands to run (alternative to --commands)")
    parser.add_argument("--commands", nargs="+", help="Commands to run")
    parser.add_argument("--file", help="File with commands (one per line)")
    parser.add_argument("--config", action="store_true",
                        help="Enter config mode (for configuration commands)")
    parser.add_argument("--output", help="Save output to file")
    args = parser.parse_args()

    if args.file:
        with open(args.file) as f:
            commands = [line.strip() for line in f if line.strip() and not line.startswith("!")]
    elif args.commands:
        commands = args.commands
    elif args.positional_commands:
        commands = args.positional_commands
    else:
        parser.print_help()
        sys.exit(1)

    if args.config:
        results = run_config_commands(commands)
    else:
        results = run_show_commands(commands)

    if args.output:
        with open(args.output, "w") as f:
            f.write(results if isinstance(results, str) else "\n".join(results))
        print(f"\nOutput saved to: {args.output}")


if __name__ == "__main__":
    main()
