"""Robot keyword library for NETCONF checks against the lab routers.

Kept as a Python library because there is no maintained NETCONF keyword library
for Robot; ncclient does the protocol work and these expose it as keywords.
"""
from xml.etree import ElementTree

from ncclient import manager

NATIVE_NS = "http://cisco.com/ns/yang/Cisco-IOS-XE-native"


def _connect(host, port, user, password):
    return manager.connect(
        host=host,
        port=int(port),
        username=user,
        password=password,
        hostkey_verify=False,
        look_for_keys=False,
        allow_agent=False,
        device_params={"name": "iosxe"},
        timeout=90,
    )


class netconf_keywords:
    ROBOT_LIBRARY_SCOPE = "GLOBAL"

    def get_netconf_hostname(self, host, port, user, password):
        """Returns the hostname from running-config over NETCONF."""
        # ncclient expects ("subtree", criteria); passing a wrapped <filter>
        # element makes IOS-XE reject it as bad-element: filter.
        criteria = '<native xmlns="%s"><hostname/></native>' % NATIVE_NS
        with _connect(host, port, user, password) as m:
            reply = m.get_config(source="running", filter=("subtree", criteria))
            root = ElementTree.fromstring(reply.xml)
            node = root.find(".//{%s}hostname" % NATIVE_NS)
            if node is None or not node.text:
                raise AssertionError("NETCONF reply carried no hostname")
            return node.text.strip()

    def get_netconf_capabilities(self, host, port, user, password):
        """Returns the server's advertised capability URIs."""
        with _connect(host, port, user, password) as m:
            return [str(c) for c in m.server_capabilities]
