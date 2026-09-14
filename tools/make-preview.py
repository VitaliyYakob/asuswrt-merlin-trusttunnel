#!/usr/bin/env python3
"""Build a self-contained, offline UI preview. It sends no router requests."""
from pathlib import Path
import json
import re
root = Path(__file__).resolve().parents[1]
page = (root / "addon/trusttunnel_page.asp").read_text()
page = re.sub(r'<link[^>]+>', '', page)
page = re.sub(r'<script src="[^"]+"></script>', '', page)
page = re.sub(r'<%.*?%>', '{}', page, flags=re.S)
page = re.sub(r'<input type="hidden" name="(?:preferred_lang|firmver)"[^>]*>', '', page)
fixture = {
    "version": (root/"VERSION").read_text().strip(), "state": "disabled", "hostname": "vpn.example.com",
    "process_running": False, "interface_up": False, "enabled": False, "connection_verified": False,
    "rx_bytes": 0, "tx_bytes": 0, "timestamp": 1789394400, "last_result": "preview:not_executed",
    "discovered_networks": [{"lan_if": f"br{i}", "sources": [f"192.168.{50+i}.0/24"]} for i in range(4)],
    "policy": json.loads((root/"examples/policy.example.json").read_text()), "hardware_tested": False
}
css = (root/"addon/web/trusttunnel.css").read_text()
js = (root/"addon/web/connection.js").read_text() + "\n" + (root/"addon/web/trusttunnel.js").read_text()
extra = '''body{background:#17252e;color:#e4edf2;font-family:Arial,sans-serif;margin:24px}
.content{width:100%;max-width:1160px}.FormTitle{background:#243640;border:1px solid #4a616d;border-radius:6px}
@media(max-width:760px){body{margin:0!important}.content>tbody>tr>td:first-child{display:none}#tabMenu{padding:16px!important;font-size:11px!important}}
#mainMenu{padding:24px 12px;font-size:15px;line-height:2.4}#tabMenu{padding:0 0 18px;font-size:15px}
'''
page = page.replace('</head>', '<style>'+css+extra+'</style><script>window.TTM_PREVIEW='+json.dumps(fixture)+';</script><script>'+js+'</script></head>')
page = page.replace('<div id="mainMenu"></div>', '<div id="mainMenu">ASUSWRT-Merlin<br>Общие настройки<br>Сеть<br>Беспроводная сеть<br><strong>VPN</strong><br>Администрирование</div>')
page = page.replace('<div id="tabMenu" class="submenuBlock"></div>', '<div id="tabMenu">VPN Client &nbsp; / &nbsp; VPN Director &nbsp; / &nbsp; <strong>TrustTunnel</strong> &nbsp; · &nbsp; OFFLINE PREVIEW</div>')
page = page.replace('ASUSWRT-Merlin — TrustTunnel', 'TrustTunnel — OFFLINE PREVIEW')
out = root / "preview/index.html"
out.parent.mkdir(exist_ok=True)
out.write_text(page)
print(out)
