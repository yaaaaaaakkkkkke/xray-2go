#!/usr/bin/env python3
"""Non-side-effect regression probes for xray_2go.sh."""
from __future__ import annotations
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "xray_2go.sh"
SRC = SCRIPT.read_text()

MASKED = "Authorization: Bearer " + "***"
TOKEN_HEADER = "Authorization: Bearer " + "${_token}"


def check(cond: bool, msg: str) -> None:
    if not cond:
        raise AssertionError(msg)


def source_probe(body: str) -> subprocess.CompletedProcess[str]:
    tmpdir = Path(tempfile.mkdtemp(prefix="xray2go-probe-"))
    try:
        copy = tmpdir / "xray_2go_probe.sh"
        text = SRC.replace('if [ "${BASH_SOURCE[0]}" = "$0" ]; then\n    main "$@"\nfi\n', '# main disabled for probe\n')
        copy.write_text(text)
        probe = tmpdir / "probe.sh"
        probe.write_text(f"set -euo pipefail\nsource {copy}\n{body}\n")
        return subprocess.run(["bash", str(probe)], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def test_cf_zone_uses_runtime_token_and_safe_query() -> None:
    check(MASKED not in SRC, "Cloudflare Authorization header must not be a literal mask")
    check(TOKEN_HEADER in SRC, "Cloudflare Authorization header must use runtime token variable")
    check('--data-urlencode "name=${_name}"' in SRC or "--data-urlencode" in SRC, "Cloudflare zone query should URL-encode name/status/per_page")


def test_acme_output_is_redacted_before_printing() -> None:
    check('redact_sensitive()' in SRC, "missing redact_sensitive helper")
    check('printf \'%s\\n\' "${_issue_out}" | redact_sensitive' in SRC or 'redact_sensitive "${_issue_out}"' in SRC, "ACME output must be redacted before printing")


def test_commit_fails_closed_on_state_persist() -> None:
    check('st_persist    || log_warn "state.json 写入失败"' not in SRC, "_commit must not warn-only on state persist failure")
    check('st_persist   || log_warn "state.json 写入失败"' not in SRC, "module disable commit must not warn-only on state persist failure")
    body = r'''
_G_STATE='{"uuid":"11111111-1111-1111-1111-111111111111","ports":{"argo":18888,"ff":8080,"reality":443,"vltcp":1234,"vlquic":443,"cforigin":28888},"argo":{"enabled":false},"ff":{"enabled":false,"protocol":"none"},"reality":{"enabled":false},"vltcp":{"enabled":false},"vlquic":{"enabled":false},"cforigin":{"enabled":false},"xpad":{"argo":true,"ff":true,"reality":true}}'
config_apply(){ return 0; }
st_persist(){ return 42; }
fw_reconcile(){ echo FW_CALLED; return 0; }
if _commit; then echo COMMIT_OK; else echo COMMIT_FAIL; fi
'''
    p = source_probe(body)
    check(p.returncode == 0, p.stderr)
    check('COMMIT_FAIL' in p.stdout, p.stdout + p.stderr)
    check('FW_CALLED' not in p.stdout, "firewall must not sync when state persist failed")


def test_install_port_conflict_uses_plugin_rules_and_udp() -> None:
    check('for _proto in argo reality vltcp; do' not in SRC, "install conflict check must not hard-code old protocol list")
    check('fw_desired_rules' in SRC and 'port_mgr_in_use_udp' in SRC, "install conflict check should use desired port/proto rules")


def test_firewall_does_not_mark_preexisting_rules_as_managed() -> None:
    check('_fw_select_backend()' in SRC, "firewall backend should be selected rather than mutating every backend")
    check('pre-existing rule is not script-owned' in SRC, "pre-existing firewall rules must not be marked as managed")
    check(r'\[[[:space:]]*[0-9]+\]' in SRC, "ufw numbered rule detection should match '[ 1]' as well as '[1]'")
    preexisting_mark_patterns = [
        r'else\n\s*_fw_mark_rule nft',
        r'_fw_rule_exists[\s\S]{0,300}_fw_mark_rule',
    ]
    for pat in preexisting_mark_patterns:
        check(not re.search(pat, SRC), "pre-existing firewall rules appear to be marked as managed")


def test_secret_prompt_exists() -> None:
    check('prompt_secret()' in SRC, "missing prompt_secret helper")
    check('read -r -s' in SRC or 'read -rs' in SRC, "prompt_secret should hide input")
    check('prompt "Cloudflare API Token' not in SRC, "Cloudflare token prompt should be hidden")
    check('prompt "Cloudflare Global API Key' not in SRC, "Cloudflare key prompt should be hidden")


def test_backup_retention_two() -> None:
    check('atomic_write_secret_with_backup "${STATE_FILE}" "${_json}" 2' in SRC, "state backup should retain latest 2")
    check('atomic_write_with_backup "${CONFIG_FILE}" "${_json}" 2' in SRC, "config backup should retain latest 2")


def main() -> None:
    tests = [v for k, v in globals().items() if k.startswith('test_') and callable(v)]
    for t in tests:
        t()
        print(f"PASS {t.__name__}")


if __name__ == "__main__":
    main()
