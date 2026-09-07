"""Robot keywords over a pyATS testbed: Unicon for connections, Genie for parsing.

The shipped Robot integration (genie.libs.robot) exposes parse and learn but not
execute, so anything imperative -- a ping, a clear, a config push -- needs a thin
wrapper like this one. Navigating Genie's nested structures is also far clearer
in Python than in Robot's Evaluate, so the dict-walking lives here and the suite
stays readable.
"""
from genie.testbed import load


class genie_keywords:
    ROBOT_LIBRARY_SCOPE = "GLOBAL"

    def __init__(self):
        self._tb = None

    # ---- connection ------------------------------------------------------
    def use_lab_testbed(self, path):
        self._tb = load(path)
        return sorted(self._tb.devices)

    def connect_lab_devices(self, *names):
        out = []
        for n in names:
            d = self._tb.devices[n]
            if not d.is_connected():
                d.connect(log_stdout=False, learn_hostname=True)
            out.append(d.hostname)
        return out

    def disconnect_lab_devices(self):
        for d in self._tb.devices.values():
            if d.is_connected():
                d.disconnect()

    def device_execute(self, name, command):
        return self._tb.devices[name].execute(command)

    def device_parse(self, name, command):
        return self._tb.devices[name].parse(command)

    # ---- derived views ---------------------------------------------------
    def tunnel_state(self, name, tunnel):
        b = self._tb.devices[name].parse("show ip interface brief")
        e = b["interface"].get(tunnel, {})
        return {"status": e.get("status"), "protocol": e.get("protocol"),
                "ip": e.get("ip_address")}

    def esp_totals(self, name):
        """(encaps, decaps) summed over every IPsec SA on the device."""
        p = self._tb.devices[name].parse("show crypto ipsec sa")
        enc = dec = 0
        for tun in p.get("interface", {}).values():
            for ident in tun.get("ident", {}).values():
                enc += ident.get("pkts_encaps", 0)
                dec += ident.get("pkts_decaps", 0)
        return enc, dec

    def ipsec_tunnels(self, name):
        return sorted(self._tb.devices[name].parse("show crypto ipsec sa").get("interface", {}))

    def outbound_transforms(self, name):
        p = self._tb.devices[name].parse("show crypto ipsec sa")
        out = []
        for tun in p.get("interface", {}).values():
            for ident in tun.get("ident", {}).values():
                # structure is ident.<n>.outbound_esp_sas.spi.<spi>.transform
                for sa in ident.get("outbound_esp_sas", {}).get("spi", {}).values():
                    if sa.get("transform"):
                        out.append(sa["transform"])
        return out

    def route_interfaces(self, name, prefix):
        """Outgoing interfaces for a prefix, from the parsed routing table."""
        p = self._tb.devices[name].parse("show ip route")
        routes = p["vrf"]["default"]["address_family"]["ipv4"]["routes"]
        entry = routes.get(prefix)
        if not entry:
            return []
        nh = entry.get("next_hop", {})
        names = [v.get("outgoing_interface") for v in nh.get("next_hop_list", {}).values()]
        names += list(nh.get("outgoing_interface", {}))
        return [n for n in names if n]
