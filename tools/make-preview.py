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
    "endpoint":{"configured":True,"exclusions":[],"settings":{"protocol":"http2","mtu":1350,"anti_dpi":False}},
    "tunnel_addresses":[],"traffic_check":None,"traffic_check_history":None,"client_updates":{"channel":"stable","installed":{"version":"1.1.5","installed_at":1790776800},"last_check":{"checked_at":1790777400,"channel":"stable"},"dependencies_ready":True,"recovery_pending":False,"check":None},
    "ports":[{"interface":f"eth{4-i}" if i<4 else "eth5","label":f"LAN{i+1}" if i<4 else "2.5G","lan_if":"br0","identity":"0"*64,"available":True,"reason":"","link_up":i==3} for i in range(5)],
    "client_uptime_seconds":None,"traffic_observation":None,
    "revision":"0123456789abcdef", "operations":[], "transaction":None,
    "clients":[{"ip":"192.168.51.10","name":"Ноутбук","wireless":[{"lan_if":"br1","ssid":"Guest 1"}]},{"ip":"192.168.50.20","name":"Телефон","wireless":[{"lan_if":"br0","ssid":"Home"}]}],
    "diagnostics":{"model":"RT-AX86U","firmware":"Не проверена","guard":"unverified","client_version_target":"1.1.5","packet_path_verified":False},
    "discovered_networks": [{"lan_if": f"br{i}", "identity":str(i)*64,"sources": [f"192.168.{50+i}.0/24"], "ssids": [["Home"],["Guest 1"],["Guest 2"],["Guest 3"]][i]} for i in range(4)],
    "policy": {"schema":3,"networks":[{"lan_if":"br1","sources":["192.168.51.0/24"]}],"block_ipv6_bridge":True,"table":871,"priority":17100}, "hardware_tested": False
}
css = (root/"addon/web/trusttunnel.css").read_text()
js = '\n'.join((root/"addon/web"/file).read_text() for file in ('connection.js','transfer.js','trusttunnel.js'))
# The firmware supplies this chrome on the router. It only exists in the offline
# preview and deliberately contains no working router navigation or controls.
extra = r'''
body{background:#20313b;color:#fff;font-family:Arial,Helvetica,sans-serif;font-size:13px;margin:0;padding:12px 18px 26px}
#TopBanner,.content,#footer{box-sizing:border-box;width:100%;max-width:1180px;margin:0 auto}
#TopBanner{border:1px solid #50646b;border-radius:7px 7px 0 0;overflow:hidden;box-shadow:0 0 9px #101d23;background:#080d10}
.preview-top{display:flex;align-items:center;gap:18px;min-height:48px;padding:0 12px;background:linear-gradient(115deg,#6595a3 0,#3b5e69 31%,#505656 32%,#202b2e 69%,#505859)}
.preview-brand{display:flex;align-items:center;gap:18px;white-space:nowrap}
.preview-asus{font-size:29px;letter-spacing:-2px;font-weight:900;font-style:italic;line-height:1;color:#fff;text-shadow:0 1px 1px #33535d}
.preview-model{font-size:20px;font-weight:bold;text-shadow:0 2px 1px #15252c}
.preview-merlin{font-size:12px;line-height:1.25;color:#dbe4e6;margin-right:auto;padding-left:10px;border-left:1px solid #78919a}
.preview-merlin strong{display:block;font-size:13px}
.preview-system{display:flex;gap:10px;align-items:center}
.preview-system button{background:linear-gradient(#26383e,#050a0c);color:#eee;border:1px solid #374b53;border-radius:10px;min-width:132px;padding:10px 14px;font:bold 13px Arial;opacity:.7;cursor:not-allowed}
.preview-system button:last-child{min-width:105px;margin-left:18px}
.preview-notice{margin:0;padding:7px 12px;color:#c5d9df;border-top:1px solid #2b464f;font-size:11px;line-height:1.4}
.preview-notice strong{color:#ffdc55;font-weight:bold;margin-right:8px}
.content{table-layout:fixed;border-spacing:0;background:#080d10;box-shadow:0 3px 9px #101d23}
.content>tbody>tr>td:first-child{width:220px!important;padding:12px 0 12px 8px;vertical-align:top}
.content>tbody>tr>td:last-child{padding:0 12px 12px 16px;vertical-align:top;min-width:0}
#mainMenu{font-size:14px;line-height:1.15}
.preview-quick{display:flex;align-items:center;gap:12px;padding:12px 10px;margin-bottom:10px;background:linear-gradient(#7c878a,#282d2f);border:1px solid #717b7f;border-radius:6px;font-weight:bold;min-height:32px}
.preview-menu-group{margin:0 0 10px;border:1px solid #697478;background:#363d40}
.preview-menu-heading{background:#4c5558;font-size:15px;font-weight:bold;text-align:center;padding:9px 6px;border-bottom:1px solid #778085}
.preview-menu-item{display:flex;align-items:center;gap:10px;min-height:45px;padding:0 9px;border-bottom:1px solid #646d71;font-weight:bold;color:#f2f4f5;text-shadow:0 1px 1px #111}
.preview-menu-item:last-child{border-bottom:0}
.preview-menu-item.is-active{background:linear-gradient(#93b0c0,#4d86ae);color:white}
.preview-icon{display:block;flex:0 0 30px;width:30px;height:30px;stroke:#97e2fa;fill:none;stroke-width:1.7;stroke-linecap:round;stroke-linejoin:round;filter:drop-shadow(0 0 1px #9de8ff)}
.preview-status{display:flex;flex-wrap:wrap;gap:7px 19px;color:#d9e1e4;padding:15px 2px 18px;font-size:12px;line-height:1.4}
.preview-status b{font-weight:bold;color:#fff}
.preview-status .preview-offline{margin-left:auto;color:#a7bdc6}
.preview-tabs{display:flex;gap:4px;align-items:stretch;margin:0;min-width:0}
.preview-tab{display:flex;align-items:center;justify-content:center;min-height:40px;padding:0 10px;background:#2f3d43;border-radius:5px 5px 0 0;border:1px solid #29393f;border-bottom:0;color:#e1e7e9;font-size:13px;white-space:nowrap}
.preview-tab[aria-current=page]{background:#4c595e;color:#fff;border-color:#4c595e;font-weight:bold}
#tabMenu{padding:0;margin:0;width:100%;height:auto}
.FormTitle{background:#4c595e;border:0;border-radius:0;margin:0;width:auto!important}
#footer{background:#080d10;padding:8px 16px 14px;color:#9dafb6;text-align:right;font-size:11px;line-height:1.4}
@media(max-width:1000px){.preview-top{gap:10px}.preview-system button{min-width:95px}.preview-system button:last-child{margin-left:0;min-width:80px}.content>tbody>tr>td:first-child{width:190px!important}.content>tbody>tr>td:last-child{padding-left:12px}.preview-menu-item{font-size:12px;gap:7px}.preview-tab{padding:0 7px;font-size:11px}.preview-status .preview-offline{margin-left:0}}
@media(max-width:760px){
body{padding:0;background:#4c595e}
#TopBanner{border-radius:0;border-width:0 0 1px;box-shadow:none}
.preview-top{min-height:49px;padding:0 12px;gap:10px}.preview-asus{font-size:25px}.preview-model{font-size:16px}.preview-brand{gap:12px}.preview-merlin{margin-left:auto;margin-right:0;font-size:10px;padding-left:9px}.preview-merlin strong{font-size:11px}.preview-system{display:none}.preview-notice{padding:7px 12px}
.content,.content>tbody,.content>tbody>tr,.content>tbody>tr>td:last-child{display:block;width:100%;max-width:none;box-sizing:border-box;box-shadow:none}
.content>tbody>tr>td:first-child{display:none}
.content>tbody>tr>td:last-child{padding:0}
.preview-status{padding:10px 12px;gap:5px 12px;font-size:11px}.preview-status .preview-offline{display:none}
.preview-tabs{padding:0 8px;gap:4px}.preview-tab{display:none;min-height:35px;padding:0 12px;font-size:12px}.preview-tab.preview-client,.preview-tab[aria-current=page]{display:flex}
#footer{padding:12px;font-size:10px;text-align:left}
}
'''
# Simple local line symbols reproduce the menu hierarchy without fetching assets.
icon_paths = {
    "network": '<circle cx="16" cy="16" r="10"/><path d="M6 16h20M16 6c-6 6-6 14 0 20M16 6c6 6 6 14 0 20M8 10h16M8 22h16"/>',
    "wifi": '<path d="M4 12c7-7 17-7 24 0M8 17c5-5 11-5 16 0M12 22c3-3 5-3 8 0"/><circle cx="16" cy="27" r="1"/>',
    "shield": '<path d="M16 3L5 8v9c0 6 5 10 11 13 6-3 11-7 11-13V8z"/><rect x="11" y="15" width="10" height="8" rx="1"/><path d="M13 15v-3a3 3 0 0 1 6 0v3"/>',
    "clients": '<circle cx="11" cy="10" r="4"/><circle cx="24" cy="12" r="3"/><path d="M3 27v-5c0-7 16-7 16 0v5M20 19c5-2 9 1 9 5v3"/>',
    "monitor": '<rect x="3" y="5" width="26" height="18" rx="1"/><path d="M12 23v5M20 23v5M8 28h16M7 14h5l3-5 4 10 3-5h3"/>',
    "settings": '<path d="M23 4a8 8 0 0 0-9 10L4 24a3 3 0 0 0 4 4l10-10a8 8 0 0 0 10-9l-5 5-5-5z"/>',
    "usb": '<path d="M16 28V5m-4 4 4-5 4 5M16 22H9a3 3 0 0 1-3-3v-4M16 17h7a3 3 0 0 0 3-3v-2"/><circle cx="6" cy="12" r="3"/><rect x="23" y="5" width="6" height="6"/><circle cx="16" cy="28" r="2"/>',
    "log": '<path d="M7 3h19v26H7zM3 7h4M3 13h4M3 19h4M3 25h4M12 9h9M12 14h9M12 19h9M12 24h6"/>',
}
def icon(name):
    return '<svg class="preview-icon" viewBox="0 0 32 32" aria-hidden="true">' + icon_paths[name] + '</svg>'

def menu_group(title, items):
    rows = ''.join('<div class="preview-menu-item' + (' is-active' if label == 'VPN' else '') + '">' + icon(symbol) + '<span>' + label + '</span></div>' for label, symbol in items)
    return '<div class="preview-menu-group"><div class="preview-menu-heading">' + title + '</div>' + rows + '</div>'

banner = '''<div id="TopBanner">
<div class="preview-top"><div class="preview-brand"><span class="preview-asus">ASUS</span><span class="preview-model">RT-AX86U</span></div>
<div class="preview-merlin">Powered by<strong>Asuswrt-Merlin</strong></div>
<div class="preview-system" aria-label="Элементы оболочки, недоступные в предпросмотре"><button type="button" disabled>Выход</button><button type="button" disabled>Перезагрузка</button><button type="button" disabled>Русский ▾</button></div></div>
<p class="preview-notice"><strong>ЛОКАЛЬНЫЙ ПРЕДПРОСМОТР</strong> Роутер не подключён. Названия сетей и состояние — демонстрационные данные; меню оболочки неактивно.</p></div>'''
menu = '<div id="mainMenu" aria-label="Образец меню прошивки"><div class="preview-quick">' + icon('settings') + '<span>Быстрая настройка<br>Интернет</span></div>'
menu += menu_group('Общие настройки', [('Карта сети','network'),('AiMesh','wifi'),('Гостевая сеть','clients'),('AiProtection','shield'),('Родительский контроль','clients'),('Адаптивный QoS','monitor'),('Анализатор трафика','monitor'),('Игры','monitor'),('Open NAT','network'),('USB-приложение','usb'),('Информация о системе','settings')])
menu += menu_group('Дополнительные настройки', [('Беспроводная сеть','wifi'),('Локальная сеть','monitor'),('Интернет','network'),('IPv6','network'),('VPN','monitor'),('Брандмауэр','shield'),('Администрирование','settings'),('Системный журнал','log'),('Сетевые утилиты','settings'),('Дополнения','settings')])
menu += '</div>'
tabs = '<div id="tabMenu" class="submenuBlock"><div class="preview-status"><span>Режим: <b>Беспроводной роутер</b></span><span>Модель: <b>RT-AX86U</b></span><span class="preview-offline">Нет подключения к прошивке</span></div><div class="preview-tabs" aria-label="Образец вкладок VPN">'
for label in ('VPN Status', 'VPN Director', 'VPN Server', 'VPN Client', 'Instant Guard', 'TrustTunnel'):
    tabs += '<span class="preview-tab' + (' preview-client' if label == 'VPN Client' else '') + '"' + (' aria-current="page"' if label == 'TrustTunnel' else '') + '>' + label + '</span>'
tabs += '</div></div>'
page = page.replace('</head>', '<style>'+css+extra+'</style><script>window.TTM_PREVIEW='+json.dumps(fixture)+';</script><script>'+js+'</script></head>')
page = page.replace('<div id="TopBanner"></div>', banner)
page = page.replace('<div id="mainMenu"></div>', menu)
page = page.replace('<div id="tabMenu" class="submenuBlock"></div>', tabs)
page = page.replace('<div id="footer"></div>', '<div id="footer">TrustTunnel · автономный предпросмотр интерфейса ASUSWRT-Merlin · без запросов к роутеру</div>')
page = page.replace('ASUSWRT-Merlin — TrustTunnel', 'TrustTunnel — OFFLINE PREVIEW')
out = root / "preview/index.html"
out.parent.mkdir(exist_ok=True)
out.write_text(page)
print(out)
