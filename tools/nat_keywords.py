"""Robot keywords for reading NAT translation tables at scale.

Parsing 40 translations per router is clearer in Python than in Robot's escaping
rules, and keeps the regex in one place.
"""
import re


class nat_keywords:
    ROBOT_LIBRARY_SCOPE = "GLOBAL"

    def translation_map(self, text, lan_prefix):
        """{inside address: outside address} for one LAN, from show ip nat translations."""
        pat = (r"^\S+\s+(\d+\.\d+\.\d+\.\d+)(?::\d+)?\s+"
               + re.escape(lan_prefix) + r"\.(\d+)(?::\d+)?\s")
        found = {}
        for outside, octet in re.findall(pat, text, re.M):
            found.setdefault(f"{lan_prefix}.{octet}", outside)
        return found

    def subset_by_octet(self, mapping, first, last):
        """Entries whose inside address ends in an octet within [first, last]."""
        lo, hi = int(first), int(last)
        return {k: v for k, v in mapping.items() if lo <= int(k.rsplit(".", 1)[1]) <= hi}

    def distinct_values(self, mapping):
        return len(set(mapping.values()))

    def octets_of(self, values):
        return sorted(int(str(v).rsplit(".", 1)[1]) for v in values)

    def mapping_is_octet_aligned(self, mapping):
        """True when every inside address maps to an outside one ending in the same octet."""
        return all(k.rsplit(".", 1)[1] == v.rsplit(".", 1)[1] for k, v in mapping.items())

    def all_within_octets(self, values, first, last):
        lo, hi = int(first), int(last)
        return all(lo <= int(str(v).rsplit(".", 1)[1]) <= hi for v in values)
