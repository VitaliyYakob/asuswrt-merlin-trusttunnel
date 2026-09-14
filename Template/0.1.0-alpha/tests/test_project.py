from __future__ import annotations
import base64
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[1]
CTL = ROOT / "addon/trusttunnel.sh"
EP = json.loads((ROOT / "examples/endpoint.example.json").read_text())
POL = json.loads((ROOT / "examples/policy.example.json").read_text())

def run(*args, env=None, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, env=env, **kwargs)

class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
    def write(self, data):
        dest = self.path / "input.json"
        dest.write_text(json.dumps(data))
        return dest
    def validate(self, kind, data):
        return run(str(CTL), "validate", kind, str(self.write(data)))
    def test_endpoint_valid(self): self.assertEqual(self.validate("endpoint", EP).returncode, 0)
    def test_policy_valid(self): self.assertEqual(self.validate("policy", POL).returncode, 0)
    def test_unknown_endpoint_field(self):
        data=copy.deepcopy(EP); data["skip_verification"]=True
        self.assertNotEqual(self.validate("endpoint", data).returncode, 0)
    def test_invalid_endpoints(self):
        for key,value in [("schema",2),("hostname","a;reboot"),("addresses",["host:99999"]),
                          ("addresses",["host:0"]),("addresses",[]),("protocol","auto"),
                          ("password",""),("password","x\ny"),("username","\u0000"),
                          ("mtu",1279),("mtu",1350.5),("dns_upstreams",[]),
                          ("wan_if","br0;reboot"),("anti_dpi","false")]:
            with self.subTest(key=key,value=value):
                data=copy.deepcopy(EP);data[key]=value
                self.assertNotEqual(self.validate("endpoint",data).returncode,0)
    def test_invalid_policies(self):
        for key,value in [("sources",["0.0.0.0/0"]),("sources",["8.8.8.8/32"]),
                          ("sources",["192.168.50.1/24"]),("sources",["192.168.300.0/24"]),
                          ("sources",["192.168.050.0/24"]),("sources",[]),
                          ("sources",["192.168.50.1/32"]*2),("sources",["10.0.0.0/7"]),
                          ("lan_if","eth0"),("lan_if","br1;reboot"),("block_ipv6_bridge",False),
                          ("table",300),("priority",100),("dns_ipv4","127.0.0.1"),
                          ("dns_ipv4","192.168.1.1"),("dns_ipv4","224.0.0.1")]:
            with self.subTest(key=key,value=value):
                data=copy.deepcopy(POL);data[key]=value
                self.assertNotEqual(self.validate("policy",data).returncode,0)
    def test_valid_private_subnets(self):
        for network in ["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","192.168.50.9/32"]:
            with self.subTest(network=network):
                data=copy.deepcopy(POL);data["sources"]=[network]
                self.assertEqual(self.validate("policy",data).returncode,0)
    def test_render_toml_roundtrip_secret(self):
        data=copy.deepcopy(EP);data["password"]='password"\\$(touch /tmp/NEVER);`id` Привет'
        data["certificate"]='-----BEGIN CERTIFICATE-----\nabc\n-----END CERTIFICATE-----'
        result=run(str(CTL),"render",str(self.write(data)))
        self.assertEqual(result.returncode,0,result.stderr)
        cfg=tomllib.loads(result.stdout)
        self.assertEqual(cfg["endpoint"]["password"],data["password"])
        self.assertEqual(cfg["endpoint"]["certificate"],data["certificate"])
        self.assertEqual(cfg["listener"]["tun"]["included_routes"],[])
        self.assertFalse(cfg["listener"]["tun"]["change_system_dns"])
        self.assertFalse(cfg["endpoint"]["skip_verification"])
        self.assertFalse(cfg["endpoint"]["has_ipv6"])
    def test_parser_error_does_not_echo_secret(self):
        secret='UNIQUE_SUPER_SECRET'
        path=self.path/"bad.json";path.write_text('{"password":"'+secret+'",broken')
        result=run(str(CTL),"validate","endpoint",str(path))
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn(secret,result.stdout+result.stderr)
    def test_large_input_rejected(self):
        data=copy.deepcopy(EP);data["password"]="x"*70000
        self.assertNotEqual(self.validate("endpoint",data).returncode,0)
    def test_symlink_rejected(self):
        src=self.write(EP); link=self.path/"link";link.symlink_to(src)
        self.assertNotEqual(run(str(CTL),"validate","endpoint",str(link)).returncode,0)
    def test_import_permissions_and_no_web_secret(self):
        env=os.environ|{"TT_ROOT":str(self.path/"sandbox")}
        result=run(str(CTL),"import-endpoint",str(self.write(EP)),env=env)
        self.assertEqual(result.returncode,0,result.stderr)
        file=self.path/"sandbox/jffs/addons/trusttunnel/config/endpoint.json"
        self.assertEqual(file.stat().st_mode & 0o777,0o600)
        status=run(str(CTL),"status",env=env)
        self.assertEqual(status.returncode,0,status.stderr)
        obj=json.loads(status.stdout)
        self.assertNotIn("password",obj)
        self.assertNotIn("username",obj)
        self.assertNotIn(EP["password"],status.stdout)
        self.assertFalse(obj["connection_verified"])
    def test_changes_refused_while_enabled(self):
        env=os.environ|{"TT_ROOT":str(self.path/"sandbox")}
        run(str(CTL),"import-policy",str(self.write(POL)),env=env)
        (self.path/"sandbox/jffs/addons/trusttunnel/config/enabled").touch()
        self.assertNotEqual(run(str(CTL),"import-policy",str(self.write(POL)),env=env).returncode,0)
    def test_sandbox_live_actions_refused(self):
        for action in ["start","pause","disable","restart","refresh","install-webui"]:
            with self.subTest(action=action):
                result=run(str(CTL),action,env=os.environ|{"TT_ROOT":str(self.path)})
                self.assertNotEqual(result.returncode,0)
                self.assertIn("prohibited with TT_ROOT",result.stderr)
    def test_unknown_event_ignored(self):
        result=run(str(CTL),"event","start","ttm_start;reboot")
        self.assertEqual(result.returncode,0)
    def test_import_preserves_old_on_invalid(self):
        env=os.environ|{"TT_ROOT":str(self.path/"sandbox")}
        run(str(CTL),"import-policy",str(self.write(POL)),env=env)
        data=copy.deepcopy(POL);data["table"]=300
        result=run(str(CTL),"import-policy",str(self.write(data)),env=env)
        self.assertNotEqual(result.returncode,0)
        saved=self.path/"sandbox/jffs/addons/trusttunnel/config/policy.json"
        self.assertEqual(json.loads(saved.read_text())["table"],871)

class PlanTests(unittest.TestCase):
    def plan(self,action):
        result=run(str(CTL),"plan",action,str(ROOT/"examples/policy.example.json"))
        self.assertEqual(result.returncode,0,result.stderr)
        return json.loads(result.stdout)
    def test_prohibit_precedes_policy_rules(self):
        plan=self.plan("guard")
        prohibit=next(i for i,x in enumerate(plan) if "prohibit" in x.get("argv",[]))
        rule=next(i for i,x in enumerate(plan) if x["op"]=="rule")
        self.assertLess(prohibit,rule)
    def test_guard_precedes_routing(self):
        plan=self.plan("guard")
        guard=next(i for i,x in enumerate(plan) if x.get("chain")=="TTM4_FWD")
        route=next(i for i,x in enumerate(plan) if x["op"]=="command")
        self.assertLess(guard,route)
    def test_guard_has_no_live_default_route(self):
        self.assertNotIn('"dev", "tt0"',json.dumps(self.plan("guard")))
    def test_ipv6_entire_bridge_and_local_dns_guarded(self):
        text=self.plan("guard")[0]["stdin"]
        self.assertIn("-A TTM6_FWD -i br1 -j REJECT",text)
        for protocol in ["tcp","udp"]:
            self.assertIn(f"-A TTM6_IN -i br1 -p {protocol} --dport 53 -j REJECT",text)
    def test_dns_both_protocols_redirected(self):
        text="\n".join(x.get("stdin","") for x in self.plan("guard"))
        for protocol in ["tcp","udp"]:
            self.assertIn(f"-p {protocol} --dport 53 -j DNAT --to-destination 1.1.1.1:53",text)
    def test_only_selected_source_is_ipv4_guarded(self):
        plan=self.plan("guard")
        text=next(x["stdin"] for x in plan if "-F TTM4_FWD" in x.get("stdin",""))
        self.assertIn("-i br1 -s 192.168.50.0/24 -j REJECT",text)
        self.assertNotIn("-A TTM4_FWD -j REJECT",text)
    def test_policy_is_iif_scoped_without_fwmark(self):
        rules=[x for x in self.plan("guard") if x["op"]=="rule"]
        self.assertEqual(rules,[dict(op="rule",priority=17100,source="192.168.50.0/24",interface="br1",table=871)])
        self.assertNotIn("fwmark",json.dumps(self.plan("guard")))
    def test_up_only_modifies_dedicated_table(self):
        plan=self.plan("up");self.assertEqual(len(plan),1)
        self.assertEqual(plan[0]["argv"],["ip","-4","route","replace","default","dev","tt0","table","871","metric","10"])
    def test_down_keeps_prohibit_and_guards(self):
        plan=self.plan("down");self.assertEqual(len(plan),1)
        self.assertNotIn("prohibit",json.dumps(plan));self.assertNotIn("detach",json.dumps(plan))
    def test_disarm_no_table_flush(self):
        plan=self.plan("disarm");self.assertNotIn("flush",json.dumps(plan))
        self.assertEqual(sum(x["op"]=="detach" for x in plan),5)
    def test_all_actions_are_valid_json(self):
        for action in ["guard","up","down","disarm"]: self.assertIsInstance(self.plan(action),list)
    def test_invalid_action_fails(self):
        self.assertNotEqual(run(str(CTL),"plan",";reboot",str(ROOT/"examples/policy.example.json")).returncode,0)

class HookMenuTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.path=Path(self.tmp.name)
    def hook(self,original,mode="install"):
        source=self.path/"hook";source.write_text(original)
        body=self.path/"body";body.write_text('/jffs/addons/trusttunnel/trusttunnel.sh hook services-start &\n')
        return run("awk","-v",f"mode={mode}","-v",f"bodyfile={body}","-f",str(ROOT/"addon/share/hooks.awk"),str(source))
    def test_hook_precedes_exit(self):
        res=self.hook('#!/bin/sh\necho other\nexit 0\n')
        self.assertEqual(res.returncode,0)
        self.assertLess(res.stdout.index("BEGIN trusttunnel"),res.stdout.index("exit 0"))
    def test_hook_idempotent(self):
        first=self.hook('#!/bin/sh\necho other\n').stdout
        self.assertEqual(self.hook(first).stdout,first)
    def test_hook_remove_preserves_other_addon(self):
        original='#!/bin/sh\n/jffs/addons/amneziawg/amneziawg.sh start\nexit 0\n'
        installed=self.hook(original).stdout
        self.assertEqual(self.hook(installed,"remove").stdout,original)
    def test_hook_invalid_marker_fails(self):
        self.assertNotEqual(self.hook('#!/bin/sh\n# BEGIN trusttunnel-merlin\n').returncode,0)
    def test_hook_empty_file(self):
        result=self.hook("");self.assertTrue(result.stdout.startswith("#!/bin/sh\n# BEGIN"))
    def menu(self,original,mode="install"):
        source=self.path/"menu";source.write_text(original)
        return run("awk","-v",f"mode={mode}","-v","page=user7.asp","-f",str(ROOT/"addon/share/menu.awk"),str(source))
    def test_menu_preserves_other_addons(self):
        original='var tab = [\n{url: "Advanced_VPNClient_Content.asp", tabName: "Client"},\n{url: "user3.asp", tabName: "AmneziaWG"},\n];\n'
        result=self.menu(original)
        self.assertEqual(result.returncode,0)
        self.assertIn('tabName: "AmneziaWG"',result.stdout)
        self.assertIn('url: "user7.asp", tabName: "TrustTunnel"',result.stdout)
        self.assertEqual(self.menu(result.stdout).stdout,result.stdout)
        self.assertEqual(self.menu(result.stdout,"remove").stdout,original)
    def test_unknown_menu_rejected(self):
        self.assertNotEqual(self.menu('var other=[];\n').returncode,0)

class ConverterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec=importlib.util.spec_from_file_location("convert_config",ROOT/"tools/convert-config.py")
        cls.mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(cls.mod)
    def test_standard_config(self):
        rendered=run(str(CTL),"render",str(ROOT/"examples/endpoint.example.json"))
        result=self.mod.convert(tomllib.loads(rendered.stdout))
        self.assertEqual(result,EP)
    def test_insecure_cert_refused(self):
        with self.assertRaises(ValueError):self.mod.convert({"endpoint":{"skip_verification":True}})
    def test_unknown_protocol_fields_refused(self):
        with self.assertRaises(ValueError):self.mod.convert({"endpoint":{"tls_profile":"chrome"}})
    def test_internal_split_routing_refused(self):
        with self.assertRaises(ValueError):self.mod.convert({"exclusions":["example.com"]})

class SourceSafetyTests(unittest.TestCase):
    def test_shell_syntax(self):
        files=list(ROOT.rglob("*.sh"))+[ROOT/"addon/S99trusttunnel"]
        for file in files:
            with self.subTest(path=file):
                for shell in [["sh"],["busybox","ash"]]:
                    res=run(*shell,"-n",str(file));self.assertEqual(res.returncode,0,res.stderr)
    def test_no_global_flush_or_eval(self):
        for file in (ROOT/"addon").rglob("*.sh"):
            text=file.read_text()
            self.assertNotIn("conntrack -F",text)
            self.assertNotIn("ip route flush",text)
            self.assertNotIn("eval ",text)
    def test_child_does_not_inherit_lock(self):
        self.assertIn('9>&- &',(ROOT/"addon/lib/service.sh").read_text())
    def test_webui_no_secret_field(self):
        text=(ROOT/"addon/trusttunnel_page.asp").read_text()
        self.assertNotIn('type="password"',text)
        self.assertNotIn('name="password"',text)
    def test_runtime_has_no_python_dependency(self):
        for file in (ROOT/"addon").rglob("*.sh"):
            self.assertNotIn("python3 ",file.read_text())

if __name__=="__main__":unittest.main(verbosity=2)
