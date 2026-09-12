"""Robot Framework keyword library for the cat9000v lab.

Talks to the switches over SSH (netmiko) and RESTCONF (requests), to the NMS
jumphost over SSH (paramiko), and to the host OS for ping/terraform.
"""
import json
import os
import sys
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

    @keyword
    def host_command_rc(self, host, command, user="cirros", password="gocubsgo", timeout=60):
        """Run a command on a CirrOS host and return its exit code (never fails)."""
        c = paramiko.SSHClient()
        c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        c.connect(host, username=user, password=password, timeout=20,
                  look_for_keys=False, allow_agent=False)
        try:
            _, out, err = c.exec_command(command, timeout=float(timeout))
            rc = out.channel.recv_exit_status()
            logger.info(f"<pre>{host}$ {command}\nrc={rc}\n{out.read().decode()}{err.read().decode()}</pre>", html=True)
        finally:
            c.close()
        return rc

    # ---- Nautobot -----------------------------------------------------------
    def _nautobot(self):
        if not hasattr(self, "_nb"):
            url = os.environ.get("NAUTOBOT_URL", "http://10.0.0.10:8080")
            token = os.environ.get("NAUTOBOT_TOKEN")
            if not token:   # the token lives in /opt/nautobot/.env on the NMS
                token = self.nms_command("grep ^NAUTOBOT_SUPERUSER_API_TOKEN /opt/nautobot/.env | cut -d= -f2").strip()
            self._nb = (url, token)
        return self._nb

    @keyword
    def nautobot_get(self, path, **params):
        """GET /api/<path> and return the parsed JSON (results list for list endpoints)."""
        url, token = self._nautobot()
        r = requests.get(f"{url}/api/{path.lstrip('/')}", params=params, timeout=60,
                         headers={"Authorization": f"Token {token}", "Accept": "application/json"})
        logger.info(f"GET {r.url} -> {r.status_code}\n{r.text[:1500]}")
        r.raise_for_status()
        return r.json()

    @keyword
    def nautobot_graphql(self, query):
        url, token = self._nautobot()
        r = requests.post(f"{url}/api/graphql/", json={"query": query}, timeout=60,
                          headers={"Authorization": f"Token {token}"})
        logger.info(f"GraphQL {query}\n-> {r.status_code} {r.text[:2000]}")
        r.raise_for_status()
        body = r.json()
        if body.get("errors"):
            raise AssertionError(f"GraphQL errors: {body['errors']}")
        return body["data"]

    @keyword
    def hosts_from_nautobot(self):
        """Build the end-host inventory (same shape as lab_vars.HOSTS) plus HOST_PATH from Nautobot.

        gateway  = HSRP VIP of the host's VLAN (or the SVI address on the connected switch)
        path     = the real SVI address of the HSRP-active switch (first traceroute hop)
        """
        data = self.nautobot_graphql("""{
          devices(role: "host") {
            name primary_ip4 { address }
            interfaces(name: "eth1") {
              mac_address untagged_vlan { vid } ip_addresses { address }
              connected_interface { name device { name } }
            }
          }
          interface_redundancy_groups {
            protocol protocol_group_id virtual_ip { address }
            interface_redundancy_group_associations { priority interface { name device { name } ip_addresses { address } } }
          }
          devices_svi: devices(role: "core-switch") { name interfaces { name ip_addresses { address } } }
        }""")
        hsrp = {int(g["protocol_group_id"]): g for g in data["interface_redundancy_groups"] if (g["protocol"] or "").lower() == "hsrp"}
        svi = {(d["name"], i["name"]): i["ip_addresses"][0]["address"].split("/")[0]
               for d in data["devices_svi"] for i in d["interfaces"] if i["ip_addresses"]}
        hosts, path = {}, {}
        for d in data["devices"]:
            e1 = d["interfaces"][0]
            vid = e1["untagged_vlan"]["vid"]
            sw, port = e1["connected_interface"]["device"]["name"], e1["connected_interface"]["name"]
            if vid in hsrp:
                g = hsrp[vid]
                gateway = g["virtual_ip"]["address"].split("/")[0]
                active = max(g["interface_redundancy_group_associations"], key=lambda a: a["priority"])
                first_hop = active["interface"]["ip_addresses"][0]["address"].split("/")[0]
            else:
                gateway = first_hop = svi[(sw, f"Vlan{vid}")]
            hosts[d["name"]] = {"mgmt": d["primary_ip4"]["address"].split("/")[0], "switch": sw,
                                "port": port.replace("GigabitEthernet", "Gi"), "vlan": str(vid),
                                "ip": e1["ip_addresses"][0]["address"].split("/")[0], "gateway": gateway,
                                "mac": e1["mac_address"].lower().replace(":", "")[:4] + "." + e1["mac_address"].lower().replace(":", "")[4:8] + "." + e1["mac_address"].lower().replace(":", "")[8:]}
            path[d["name"]] = [first_hop]
        names = sorted(hosts)
        for n in names:                                   # peer = the other host (two-host lab)
            hosts[n]["peer"] = next(o for o in names if o != n)
        logger.info(f"hosts from Nautobot: {json.dumps(hosts, indent=1)}\npaths: {path}")
        return hosts, path

    @keyword
    def nautobot_run_job(self, job_name, timeout=600, **data):
        """Run a Nautobot job by name with the given data, wait for it, return its status string."""
        url, token = self._nautobot()
        hdr = {"Authorization": f"Token {token}", "Accept": "application/json"}
        jobs = requests.get(f"{url}/api/extras/jobs/", params={"name": job_name}, headers=hdr, timeout=60).json()["results"]
        if len(jobs) != 1:
            raise AssertionError(f"job {job_name!r} not found")
        r = requests.post(f"{url}/api/extras/jobs/{jobs[0]['id']}/run/", json={"data": data}, headers=hdr, timeout=60)
        r.raise_for_status()
        jr = r.json()["job_result"]["id"]
        deadline = time.time() + float(timeout)
        while time.time() < deadline:
            st = requests.get(f"{url}/api/extras/job-results/{jr}/", headers=hdr, timeout=60).json()["status"]["value"]
            if st in ("SUCCESS", "FAILURE", "REVOKED"):
                logger.info(f"job {job_name}: {st} ({url}/extras/job-results/{jr}/)")
                return st
            time.sleep(5)
        raise AssertionError(f"job {job_name} did not finish within {timeout}s")

    @keyword
    def switch_config(self, host, *lines):
        """Push configuration lines to a switch over SSH (used to simulate drift; tests must restore it)."""
        out = self._conn(host).send_config_set(list(lines), read_timeout=60)
        logger.info(f"<pre>{out}</pre>", html=True)
        return out

    @keyword
    def render_nac_check(self):
        """Run nautobot/render_nac.py --check; returns its exit code (0 = devices.nac.yaml matches Nautobot)."""
        url, token = self._nautobot()
        r = subprocess.run([sys.executable, str(LAB_DIR / "nautobot" / "render_nac.py"), "--check"],
                           capture_output=True, text=True, timeout=120,
                           env={**os.environ, "NAUTOBOT_URL": url, "NAUTOBOT_TOKEN": token})
        logger.info(f"<pre>{r.stdout[-4000:]}\n{r.stderr[-1000:]}</pre>", html=True)
        return r.returncode

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
