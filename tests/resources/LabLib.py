"""Robot Framework keyword library for the cat9000v lab.

Talks to the switches over SSH (netmiko) and RESTCONF (requests), to the NMS
jumphost over SSH (paramiko), and to the host OS for ping/terraform.
"""
import json
import os
import socket
import subprocess
import time
from pathlib import Path

import paramiko
import requests
import urllib3
from netmiko import ConnectHandler
from robot.api import logger
from robot.api.deco import keyword, library

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

LAB_DIR = Path(__file__).resolve().parents[2]
USERNAME = os.environ.get("IOSXE_USERNAME", "admin")
PASSWORD = os.environ.get("IOSXE_PASSWORD", "admin")


@library(scope="GLOBAL")
class LabLib:
    def __init__(self):
        self._ssh = {}   # device host -> netmiko connection
        self._nms = None

    # ---- switches: SSH ---------------------------------------------------
    def _conn(self, host):
        if host not in self._ssh:
            self._ssh[host] = ConnectHandler(
                device_type="cisco_xe", host=host, username=USERNAME,
                password=PASSWORD, secret=PASSWORD, fast_cli=False,
            )
            self._ssh[host].enable()
        return self._ssh[host]

    @keyword
    def run_command(self, host, command, timeout=60):
        """Run a show/exec command on a switch over SSH and return its output."""
        out = self._conn(host).send_command(command, read_timeout=float(timeout))
        logger.info(f"<pre>{host}# {command}\n{out}</pre>", html=True)
        return out

    @keyword
    def get_running_config(self, host):
        return self._conn(host).send_command("show running-config", read_timeout=120)

    @keyword
    def close_all_connections(self):
        for c in self._ssh.values():
            try:
                c.disconnect()
            except Exception:
                pass
        self._ssh.clear()
        if self._nms:
            self._nms.close()
            self._nms = None

    # ---- switches: RESTCONF ----------------------------------------------
    @keyword
    def restconf_get(self, host, path):
        """GET /restconf/data/<path> and return the parsed JSON."""
        url = f"https://{host}/restconf/data/{path}"
        r = requests.get(url, auth=(USERNAME, PASSWORD), verify=False, timeout=30,
                         headers={"Accept": "application/yang-data+json"})
        logger.info(f"GET {url} -> {r.status_code}\n{r.text[:2000]}")
        r.raise_for_status()
        return r.json() if r.text else {}

    # ---- NMS jumphost: SSH -----------------------------------------------
    def _nms_conn(self, host, user):
        if self._nms is None:
            c = paramiko.SSHClient()
            c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            c.connect(host, username=user, timeout=20, allow_agent=True, look_for_keys=True)
            self._nms = c
        return self._nms

    @keyword
    def nms_command(self, command, host="10.0.0.10", user="lab", timeout=60):
        """Run a shell command on the NMS jumphost; returns stdout (fails on non-zero rc)."""
        c = self._nms_conn(host, user)
        _, out, err = c.exec_command(command, timeout=float(timeout))
        rc = out.channel.recv_exit_status()
        stdout, stderr = out.read().decode(), err.read().decode()
        logger.info(f"<pre>nms$ {command}\nrc={rc}\n{stdout}{stderr}</pre>", html=True)
        if rc != 0:
            raise AssertionError(f"'{command}' on NMS failed rc={rc}: {stderr.strip() or stdout.strip()}")
        return stdout

    # ---- CirrOS end hosts: SSH (password auth, no keys) --------------------
    @keyword
    def host_command(self, host, command, user="cirros", password="gocubsgo", timeout=60):
        """Run a shell command on a CirrOS host over SSH; returns stdout+stderr, fails on non-zero rc."""
        c = paramiko.SSHClient()
        c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        c.connect(host, username=user, password=password, timeout=20,
                  look_for_keys=False, allow_agent=False)
        try:
            _, out, err = c.exec_command(command, timeout=float(timeout))
            rc = out.channel.recv_exit_status()
            text = out.read().decode() + err.read().decode()
        finally:
            c.close()
        logger.info(f"<pre>{host}$ {command}\nrc={rc}\n{text}</pre>", html=True)
        if rc != 0:
            raise AssertionError(f"'{command}' on {host} failed rc={rc}: {text.strip()[-300:]}")
        return text

    # ---- host-side helpers -----------------------------------------------
    @keyword
    def host_ping(self, target, count=3):
        """ICMP ping from the host; fails unless at least one reply."""
        r = subprocess.run(["ping", "-c", str(count), "-W", "2", target], capture_output=True, text=True)
        logger.info(r.stdout)
        if r.returncode != 0:
            raise AssertionError(f"no ICMP reply from {target}")

    @keyword
    def tcp_port_should_be_open(self, host, port, timeout=5):
        with socket.socket() as s:
            s.settimeout(float(timeout))
            try:
                s.connect((host, int(port)))
            except OSError as e:
                raise AssertionError(f"{host}:{port} not reachable: {e}")

    @keyword
    def terraform_plan_exit_code(self):
        """Run `terraform plan -detailed-exitcode` via lab.sh nac: 0 = no drift, 2 = changes."""
        r = subprocess.run([str(LAB_DIR / "lab.sh"), "nac", "plan", "-detailed-exitcode",
                            "-no-color", "-input=false", "-lock=false"],
                           capture_output=True, text=True, timeout=600)
        logger.info(f"<pre>{r.stdout[-6000:]}\n{r.stderr[-2000:]}</pre>", html=True)
        return r.returncode

    @keyword
    def save_text_file(self, path, content):
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
        logger.info(f"wrote {p} ({len(content)} bytes)")
        return str(p)

    @keyword
    def unique_marker(self, prefix="robot"):
        return f"{prefix}-{int(time.time())}"
