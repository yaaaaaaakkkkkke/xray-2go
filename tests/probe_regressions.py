#!/usr/bin/env python3
from pathlib import Path
import re
import subprocess
import sys
import time


TESTS_DIR = Path(__file__).resolve().parent
if str(TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(TESTS_DIR))

from sandbox_runner import XraySandbox


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "xray_2go.sh"
TEXT = SCRIPT.read_text(encoding="utf-8")
README = ROOT / "README.md"
README_TEXT = README.read_text(encoding="utf-8")


def assert_true(cond, msg):
    if not cond:
        raise AssertionError(msg)


def run_bash(script: str) -> str:
    with XraySandbox() as sandbox:
        cp = subprocess.run(
            ["bash", "-lc", script],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=True,
        )
    return cp.stdout


def run_bash_result(script: str) -> subprocess.CompletedProcess[str]:
    with XraySandbox() as sandbox:
        return subprocess.run(
            ["bash", "-lc", script],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )


def test_runtime_harness_does_not_touch_host_root():
    from sandbox_runner import XraySandbox

    host_root = Path("/etc/xray2go")

    def metadata(path: Path):
        if not path.exists():
            return (False, None, None)
        stat = path.stat()
        return (True, stat.st_mode, stat.st_mtime_ns)

    host_before = metadata(host_root)
    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                "source ./xray_2go.sh; "
                "printf 'root=%s\\n' \"${_X2G_ROOT}\"; "
                "printf 'work=%s\\n' \"${WORK_DIR}\"; "
                "printf 'xray=%s\\n' \"${XRAY_BIN}\"; "
                "printf 'argo=%s\\n' \"${ARGO_BIN}\"; "
                "printf 'config=%s\\n' \"${CONFIG_FILE}\"; "
                "printf 'state=%s\\n' \"${STATE_FILE}\"; "
                "printf 'plugins=%s\\n' \"${PLUGIN_DIR}\"; "
                "printf 'shortcut=%s\\n' \"${SHORTCUT}\"; "
                "printf 'self=%s\\n' \"${SELF_DEST}\"; "
                "printf 'sysctl=%s\\n' \"${_SYSCTL_FILE}\";",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )
        assert_true(cp.returncode == 0, f"sandbox source must succeed (rc={cp.returncode}): {cp.stdout}")
        expected_root = sandbox.root
        expected = {
            "root": expected_root,
            "work": expected_root / "etc/xray2go",
            "xray": expected_root / "etc/xray2go/xray",
            "argo": expected_root / "etc/xray2go/argo",
            "config": expected_root / "etc/xray2go/config.json",
            "state": expected_root / "etc/xray2go/state.json",
            "plugins": expected_root / "etc/xray2go/plugins",
            "shortcut": expected_root / "usr/local/bin/s",
            "self": expected_root / "usr/local/bin/xray2go",
            "sysctl": expected_root / "etc/sysctl.d/99-xray2go.conf",
        }
        actual = dict(
            line.split("=", 1)
            for line in cp.stdout.splitlines()
            if "=" in line
        )
        for name, path in expected.items():
            assert_true(actual.get(name) == str(path), f"{name} escaped sandbox: {actual.get(name)!r} != {path}")
        sandbox_path = sandbox.root

    assert_true(not sandbox_path.exists(), f"sandbox must be removed after harness exit: {sandbox_path}")
    assert_true(metadata(host_root) == host_before, "host /etc/xray2go changed during sandbox path probe")


def test_state_backup_and_restore_are_confined_to_sandbox():
    from sandbox_runner import XraySandbox

    host_root = Path("/etc/xray2go")

    def metadata(path: Path):
        if not path.exists():
            return (False, None, None)
        stat = path.stat()
        return (True, stat.st_mode, stat.st_mtime_ns)

    host_before = metadata(host_root)
    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}"
st_init
st_persist
st_set '.uuid = "11111111-1111-4111-8111-111111111111"'
st_persist
atomic_write_secret "${CONFIG_FILE}" '{"version":1}'
atomic_write_secret_with_backup "${CONFIG_FILE}" '{"version":2}' 2
atomic_write_secret "${WORK_DIR}/tunnel.yml" 'tunnel: fixture'

is_systemd() { return 0; }
_svc_write_file() {
    case "$1" in
        "${_X2G_ROOT}"/*) atomic_write "$1" "$2" ;;
        *) printf 'escaped_service_path=%s\\n' "$1" >&2; return 97 ;;
    esac
}
svc_apply_xray
xray_rc=$?
svc_apply_tunnel
tunnel_rc=$?
printf 'xray_rc=%s\\n' "${xray_rc}"
printf 'tunnel_rc=%s\\n' "${tunnel_rc}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )
        assert_true(cp.returncode == 0, f"sandbox artifact probe process failed: {cp.stdout}")
        assert_true("xray_rc=0" in cp.stdout, f"xray service artifact escaped sandbox: {cp.stdout}")
        assert_true("tunnel_rc=0" in cp.stdout, f"tunnel service artifact escaped sandbox: {cp.stdout}")

        expected_files = [
            sandbox.root / "etc/xray2go/state.json",
            sandbox.root / "etc/xray2go/config.json",
            sandbox.root / "etc/xray2go/.argo_env",
            sandbox.root / "etc/xray2go/tunnel.yml",
            sandbox.root / "etc/systemd/system/xray2go.service",
            sandbox.root / "etc/systemd/system/tunnel2go.service",
        ]
        for path in expected_files:
            assert_true(path.is_file(), f"expected sandbox artifact missing: {path}")

        state_backups = sorted((sandbox.root / "etc/xray2go").glob("state.json.*.bak"))
        config_backups = sorted((sandbox.root / "etc/xray2go").glob("config.json.*.bak"))
        assert_true(state_backups, "state backup must be retained inside sandbox")
        assert_true(config_backups, "config backup must be retained inside sandbox")
        for path in [expected_files[0], expected_files[1], expected_files[2], *state_backups, *config_backups]:
            assert_true(path.stat().st_mode & 0o777 == 0o600, f"sensitive artifact mode is not 0600: {path}")

        leftovers = [
            path
            for path in sandbox.root.rglob("*")
            if path.name.startswith(".tmp_") or path.name.startswith("probe_")
        ]
        assert_true(not leftovers, f"temporary artifacts leaked after fresh process exit: {leftovers}")

    assert_true(metadata(host_root) == host_before, "host /etc/xray2go changed during sandbox artifact probe")


def test_runtime_probe_matrix_runs_in_fresh_process():
    from probe_matrix import discover_probe_matrix, run_probe_matrix

    probe_source = Path(__file__)
    matrix = discover_probe_matrix(probe_source)
    assert_true(set(matrix) == {"static", "safe", "sandbox"}, "probe matrix must expose static/safe/sandbox categories")
    names = [name for category in matrix.values() for name in category]
    assert_true(len(names) == len(set(names)), "probe matrix must not duplicate test names")
    assert_true(matrix["static"], "probe matrix must discover static probes")
    assert_true(matrix["safe"], "probe matrix must discover subprocess probes")
    assert_true(matrix["sandbox"], "probe matrix must discover explicit sandbox probes")

    report = run_probe_matrix(probe_source, categories=("static", "safe", "sandbox"))
    assert_true(report["failed"] == [], f"fresh-process probe matrix failures: {report}")
    assert_true(report["executed"] == names, "probe matrix must execute every discovered probe exactly once")
    assert_true(all(item["pid"] > 0 for item in report["results"]), "each probe must report a child process")


def test_function_boundaries_after_source():
    out = run_bash(
        "source ./xray_2go.sh; "
        "declare -F _pause _hr _print_link urlencode_path redact_sensitive prompt_secret; "
        "type _hr >/dev/null"
    )
    for fn in ["_pause", "_hr", "_print_link", "urlencode_path", "redact_sensitive", "prompt_secret"]:
        assert_true(fn in out, f"{fn} must be declared after sourcing script")


def test_cf_zone_uses_runtime_token_and_safe_query():
    m = re.search(r"acme_cf_find_zone\(\) \{(?P<body>.*?)\n\}", TEXT, re.S)
    assert_true(m, "acme_cf_find_zone function missing")
    body = m.group("body")
    assert_true("Authorization: Bearer" in body and "_token" in body, "Cloudflare Zone API must use runtime token variable")
    assert_true("Bearer ***" not in body, "redacted placeholder must not be used for real API auth")
    assert_true("--get" in body, "Cloudflare zone query should use curl --get")
    assert_true("--data-urlencode" in body and "_name" in body, "Cloudflare zone name must be URL encoded")
    assert_true("status=active" in body, "Cloudflare zone status must be encoded")


def test_acme_output_is_redacted_before_printing():
    assert_true("redact_sensitive()" in TEXT, "redaction helper missing")
    assert_true('printf \'%s\\n\' "${_issue_out}" | redact_sensitive' in TEXT, "ACME output must be redacted before printing")
    assert_true('_last_out="${_issue_out}"' in TEXT, "raw ACME output should remain available for retry/error detection")


def test_commit_fails_closed_on_state_persist():
    assert_true('st_persist || log_warn' not in TEXT, "state persistence must not be warn-only")
    assert_true('拒绝同步防火墙以避免状态漂移' in TEXT, "commit/disable paths should fail closed before firewall sync")


def test_install_port_conflict_uses_plugin_rules_and_udp():
    assert_true('for _proto in argo reality vltcp' not in TEXT, "install port check must not use hard-coded protocol list")
    assert_true('_rules=$(fw_desired_rules)' in TEXT and 'while IFS= read -r _rule; do' in TEXT, "install port check should derive from desired firewall rules")
    assert_true('port_mgr_in_use_udp' in TEXT, "install port check must cover UDP")


def test_firewall_does_not_mark_preexisting_rules_as_managed():
    assert_true('_fw_select_backend()' in TEXT, "firewall backend selector missing")
    assert_true('if _fw_rule_exists "${_backend}" "${_port}" "${_proto}"; then' in TEXT, "pre-existing firewall rules should be detected")
    assert_true('pre-existing rule is not script-owned; do not mark it as managed' in TEXT, "pre-existing rules should not be marked as script-managed")


def test_secret_prompt_exists():
    assert_true('prompt_secret()' in TEXT, "prompt_secret helper missing")
    for label in ["Cloudflare API Token", "Cloudflare Global API Key", "Argo 固定 Tunnel token", "私钥路径"]:
        assert_true(f'prompt "{label}' not in TEXT, f"sensitive prompt should not echo: {label}")


def test_home_fallback_is_initialized_for_process_substitution_runs():
    assert_true('if [ -z "${HOME:-}" ]; then' in TEXT and 'export HOME="${_DETECTED_HOME}"' in TEXT, 'script should initialize HOME fallback before later HOME-dependent logic')
    out = run_bash("""
        unset HOME
        source ./xray_2go.sh
        printf 'home=%s\\n' "${HOME}"
        lifecycle_cleanup_cloudflared
        printf 'cleanup-ok\\n'
    """)
    assert_true('home=' in out and 'cleanup-ok' in out, 'script should survive unset HOME and cloudflared cleanup path')


def test_backup_retention_two():
    assert_true('atomic_write_secret_with_backup "${STATE_FILE}" "${_json}" 2' in TEXT, "state backup retention should be 2")
    assert_true('atomic_write_with_backup "${CONFIG_FILE}" "${_json}" 2' in TEXT, "config backup retention should be 2")


def test_systemd_hardening_templates():
    for token in ["PrivateTmp=yes", "ProtectHome=yes", "ProtectSystem=full", "ReadWritePaths=%s", "StandardOutput=journal", "StandardError=journal"]:
        assert_true(token in TEXT, f"systemd hardening token missing: {token}")


def test_vlquic_link_includes_explicit_h3_parameters():
    start = TEXT.index("_plg_vlquic_link()")
    end = TEXT.index("PLUGIN_EOF", start)
    body = TEXT[start:end]
    for token in ["type=xhttp", "mode=stream-one", "xhttpModeH3=true", "alpn=h3"]:
        assert_true(token in body, f"VLESS-XHTTP-H3 share link missing explicit {token}")
    assert_true("#VLESS-XHTTP-H3" in body, "VLESS-XHTTP-H3 link tag missing")


def test_cforigin_edge_h3_toggle_and_link():
    assert_true('"edge_h3": false' in TEXT, "CF Origin edge_h3 default missing")
    assert_true(".cforigin.edge_h3 = false" in TEXT, "CF Origin edge_h3 normalization/reset missing")
    assert_true("实验性客户端到 Cloudflare Edge HTTP/3" in TEXT, "initial CF Origin Edge HTTP/3 prompt must mark experimental")
    assert_true("切换客户端到 Cloudflare Edge HTTP/3" in TEXT, "CF Origin management toggle missing")
    assert_true('"&alpn=h3&extra=%7B%22xhttpModeH3%22%3Atrue%7D&xhttpModeH3=true"' in TEXT, "CF Origin XHTTP H3 link parameters must include extra and compatibility flag")
    assert_true("CF-Origin-XHTTP-H3-Experimental" in TEXT, "CF Origin H3 link tag must mark experimental")
    assert_true("这不是 H3/QUIC 源站回源" in TEXT, "Cloudflare hint must clarify Edge H3 is not origin H3")
    assert_true("失败可回退普通 XHTTP/WS" in TEXT, "Cloudflare H3 prompt/hint must include rollback path")


def test_state_migrates_legacy_cforigin_port():
    assert_true('.cforigin.port // empty' in TEXT and "_st_migrate_port '.cforigin.port' '.ports.cforigin'" in TEXT and 'del(${_legacy_path})' in TEXT, "legacy cforigin.port must migrate into ports.cforigin")


def test_firewall_sync_fails_closed_and_prefers_active_managers():
    assert_true("ufw status" in TEXT and TEXT.index("ufw status") < TEXT.index("_fw_has_nftables; then printf 'nft'"), "active ufw should be preferred before raw nft")
    open_body = TEXT[TEXT.index('_fw_open_port()'):TEXT.index('_fw_close_port()')]
    assert_true('return 1' in open_body, "_fw_open_port must propagate backend failures")
    assert_true('_failed=0' in TEXT and '_fw_open_port "${_rp}" "${_rproto}" || _failed=1' in TEXT, "fw_reconcile must track firewall open failures")
    assert_true('部分防火墙规则同步失败' in TEXT, "fw_reconcile must report partial firewall failures")
    close_body = TEXT[TEXT.index('_fw_close_port()'):TEXT.index('fw_reconcile()')]
    assert_true('for _handle in $(nft -a list chain inet xray2go input' in close_body, "nft cleanup must delete all matching handles")
    assert_true('head -1' not in close_body, "nft cleanup must not delete only the first matching handle")


def test_config_detects_wildcard_listen_conflicts_and_filters_links():
    assert_true('_is_wild_listen()' in TEXT, "wildcard listen helper missing")
    assert_true('_used_wild_ports' in TEXT and '_used_exact_keys' in TEXT, "config build must track wildcard ports and exact listen keys separately")
    assert_true('printf \'%s\\n\' "${_used_wild_ports}" | grep -qxF "${_port}"' in TEXT, "specific listen must conflict with existing wildcard same-port listener")
    assert_true('printf \'%s\\n\' "${_used_exact_keys}" | grep -qE ":${_port}$"' in TEXT, "wildcard listen must conflict with existing specific same-port listener")
    assert_true("^(vless|trojan|socks|http)://" in TEXT and "grep -E" in TEXT, "node output should filter plugin link noise and print supported share links")


def test_plugin_loader_validates_before_source_and_loads_in_subshell():
    body = TEXT[TEXT.index('plugin_load_all()'):TEXT.index('plugin_install_builtins()')]
    assert_true('val_plugin_name "${_name}"' in body, "plugin loader must validate plugin filename before source")
    assert_true('_plugin_contract_ok' in body, "plugin loader must inspect plugin contract before source")
    assert_true('bash -n "${_f}"' in TEXT, "plugin loader must syntax-check plugin before source")
    assert_true('(\n        # 先在子 shell' in TEXT and 'source "${_f}" >/dev/null 2>&1 || exit 1' in TEXT, "plugin contract check should source in a subshell first")
    assert_true('插件文件名不合法' in TEXT and '接口不完整，已跳过且未加载' in TEXT, "plugin loader should report rejected plugins clearly")


def test_plugin_refresh_runtime_is_the_single_bootstrap_entry():
    refresh_body = TEXT[TEXT.index('plugin_refresh_runtime()'):TEXT.index('\n}\n', TEXT.index('plugin_refresh_runtime()'))]
    assert_true('plugin_install_builtins' in refresh_body and 'plugin_load_all' in refresh_body, 'plugin refresh must own builtin write + registry rebuild')
    install_core_body = TEXT[TEXT.index('module_xray_install_core()'):TEXT.index('\n}\n', TEXT.index('module_xray_install_core()'))]
    main_body = TEXT[TEXT.index('main()'):TEXT.index('if [ "${BASH_SOURCE[0]}" = "$0" ]; then', TEXT.index('main()'))]
    assert_true('plugin_refresh_runtime' in install_core_body, 'install core should reuse plugin_refresh_runtime')
    assert_true('plugin_refresh_runtime' in main_body, 'main entry should reuse plugin_refresh_runtime')


def test_plugin_collectors_drive_firewall_config_and_node_output():
    fw_body = TEXT[TEXT.index('fw_desired_rules()'):TEXT.index('\n}\n', TEXT.index('fw_desired_rules()'))]
    cfg_body = TEXT[TEXT.index('config_build_inbounds()'):TEXT.index('\n}\n', TEXT.index('config_build_inbounds()'))]
    nodes_body = TEXT[TEXT.index('config_print_nodes()'):TEXT.index('\n}\n', TEXT.index('config_print_nodes()'))]
    snapshot_body = TEXT[TEXT.index('_plugin_snapshot_rebuild()'):TEXT.index('\n}\n', TEXT.index('_plugin_snapshot_rebuild()'))]
    assert_true('plugin_collect_ports_raw' in fw_body, 'firewall desired rules should use shared plugin port collector')
    assert_true('plugin_collect_inbounds' in cfg_body, 'config_build_inbounds should delegate to shared inbound collector')
    assert_true('plugin_collect_links' in nodes_body, 'node output should delegate to shared link collector')
    for token in ['_PLUGIN_SNAPSHOT_PORTS', '_PLUGIN_SNAPSHOT_LINKS', '_PLUGIN_SNAPSHOT_INBOUNDS', 'plugin_call "${_name}" ports', 'plugin_call "${_name}" link', 'plugin_call "${_name}" inbound']:
        assert_true(token in snapshot_body, f'plugin snapshot rebuild should collect all plugin dimensions once: {token}')


def test_argo_env_final_token_validation_and_menu_install_state():
    env_body = TEXT[TEXT.index('_svc_write_argo_env()'):TEXT.index('svc_apply_xray()')]
    assert_true('val_argo_token' in env_body, "Argo env writer must revalidate final token before writing env")
    assert_true('Argo token 格式异常，拒绝写入 env' in TEXT, "Argo env writer should fail closed on invalid persisted token")
    assert_true('check_xray_install()' in TEXT and '_MENU_XI' in TEXT, "menu should track installed state separately from running state")
    assert_true('Xray-2go 已安装但未运行' in TEXT, "install menu should not treat stopped service as uninstalled")
    assert_true('自动修正' not in TEXT and '不会自动更换' in TEXT, "port conflict prompts must match current fail/manual behavior")


def test_install_service_and_firewall_fail_closed_status():
    install_body = TEXT[TEXT.index('module_xray_install_core()'):TEXT.index('module_xray_uninstall()')]
    helper_body = TEXT[TEXT.index('svc_enable_start_verify()'):TEXT.index('# ==============================================================================', TEXT.index('svc_enable_start_verify()'))]
    assert_true('fw_reconcile || { _install_rollback' in install_body, "install must rollback/fail when firewall reconcile fails")
    assert_true('svc_enable_start_verify "${_SVC_XRAY}" 8 required' in install_body, "xray install start path should use shared verified start helper")
    assert_true('svc_enable_start_verify "${_SVC_TUNNEL}" 6 required' in install_body, "Argo install must require verified Tunnel startup")
    assert_true('svc_exec_mut enable "${_svc}"' in helper_body and 'svc_exec_mut start  "${_svc}"' in helper_body, "service helper must centralize enable/start")
    assert_true('svc_verify_health "${_svc}" "${_max}"' in helper_body, "service helper must verify health when max wait > 0")
    assert_true('log_ok "${_svc} 已启动"' in helper_body, "service helper success message missing")
    assert_true('log_warn "${_svc} 启动失败' in helper_body, "optional service start failure warning missing")


def test_argo_install_tunnel_failure_rolls_back_before_state_commit():
    cp = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE="${_STATE_DEFAULT}"
        _st_normalize_schema >/dev/null
        st_set '.argo.enabled = true' >/dev/null
        clear() { :; }
        platform_preflight() { :; }
        plugin_refresh_runtime() { :; }
        _install_detect_existing_xray() { return 1; }
        _install_check_port_conflicts() { :; }
        download_xray() { :; }
        download_cloudflared() { :; }
        config_apply() { :; }
        svc_apply_xray() { :; }
        svc_apply_tunnel() { :; }
        svc_reload_daemon() { :; }
        is_openrc() { return 1; }
        platform_fix_time_sync() { :; }
        fw_reconcile() { :; }
        _install_rollback() { printf 'install-rollback-called\\n'; return 0; }
        svc_enable_start_verify() {
            printf 'svc-call=%s max=%s mode=%s\\n' "$1" "$2" "$3"
            [ "$1" = "${_SVC_TUNNEL}" ] && return 1
            return 0
        }
        st_persist() { printf 'state-persist-called\\n'; return 0; }
        module_xray_install_core
        rc=$?
        printf 'install-rc=%s enabled=%s\\n' "$rc" "$(st_get '.argo.enabled')"
        exit 0
    """)
    assert_true(cp.returncode == 0, f"Argo install failure probe process failed: {cp.stdout}")
    assert_true("svc-call=tunnel2go max=6 mode=required" in cp.stdout, f"Argo install must use required Tunnel health verification: {cp.stdout}")
    assert_true("install-rollback-called" in cp.stdout, f"Tunnel failure must trigger install rollback: {cp.stdout}")
    assert_true("install-rc=1" in cp.stdout and "state-persist-called" not in cp.stdout, f"Tunnel failure must fail before state persistence: {cp.stdout}")


def test_argo_restart_health_failure_restores_service_lifecycle():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}"
st_init >/dev/null 2>&1
st_set '.argo.enabled = true' >/dev/null
st_persist >/dev/null 2>&1
_SERVICE_ACTIVE=1
_SERVICE_ENABLED=1
svc_exec() { [ "$1" = status ] && [ "${_SERVICE_ACTIVE}" = 1 ]; }
svc_is_enabled() { [ "${_SERVICE_ENABLED}" = 1 ]; }
svc_exec_mut() {
    case "$1" in
        restart) _SERVICE_ACTIVE=0; return 0 ;;
        start) _SERVICE_ACTIVE=1; return 0 ;;
        stop) _SERVICE_ACTIVE=0; return 0 ;;
        enable) _SERVICE_ENABLED=1; return 0 ;;
        disable) _SERVICE_ENABLED=0; return 0 ;;
    esac
    return 1
}
svc_verify_health() { printf 'argo-health-called\\n'; return 1; }
module_argo_restart >/dev/null 2>&1
_rc=$?
printf 'rc=%s active=%s enabled=%s\\n' "${_rc}" "${_SERVICE_ACTIVE}" "${_SERVICE_ENABLED}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"Argo restart rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 active=1 enabled=1" in cp.stdout,
        f"Argo restart health failure must restore service lifecycle state: {cp.stdout}",
    )


def test_menu_status_and_commit_helpers_are_shared():
    menu_helpers = TEXT[TEXT.index('_menu_input_port_proto()'):TEXT.index('check_xray_install()')]
    for helper in ['_xray_runtime_status()', '_menu_print_module_status()', '_module_apply_persist_print()', '_unified_mode_label()', '_unified_render_mode_header()', '_unified_runtime_status_for()', '_unified_runtime_toggle()']:
        assert_true(helper in TEXT or helper in menu_helpers, f"shared menu helper missing: {helper}")


def test_single_file_module_registry_drives_main_status():
    assert_true('_MODULE_IDS="argo ff reality vltcp vlquic cforigin socks http"' in TEXT, "single-file module registry must list all modules")
    assert_true('module_summary()' in TEXT and 'module_label()' in TEXT, "module metadata helpers missing")
    collect_body = TEXT[TEXT.index('_menu_collect_status()'):TEXT.index('_menu_render()')]
    for mod in ['argo', 'ff', 'reality', 'vltcp', 'vlquic', 'cforigin', 'socks', 'http']:
        assert_true(f'module_summary {mod}' in collect_body, f"main status should be driven by module_summary for {mod}")
    assert_true('module_dispatch()' in TEXT, "module dispatcher skeleton missing")
    menu_body = TEXT[TEXT.index('menu()'):TEXT.index('# ==============================================================================', TEXT.index('menu()'))]
    for key, mod in [('1', 'xray install'), ('2', 'xray uninstall'), ('3', 'argo'), ('4', 'reality'), ('5', 'vltcp'), ('6', 'vlquic'), ('7', 'ff'), ('8', 'cforigin'), ('9', 'nodes show'), ('10', 'config update_uuid'), ('11', 'socks'), ('12', 'http'), ('s', 'config update_shortcut')]:
        assert_true(f'{key}) module_dispatch {mod} ;;' in menu_body, f"main menu should route {mod} via module_dispatch")
    for forbidden in ['_menu_do_install', 'exec_uninstall', 'config_print_nodes', 'cforigin_print_cloudflare_hint', 'exec_update_uuid', 'exec_update_shortcut']:
        assert_true(forbidden not in menu_body, f"main menu should be dispatcher-only, found direct action: {forbidden}")


def test_single_file_module_dispatch_actions():
    dispatch_body = TEXT[TEXT.index('module_dispatch()'):TEXT.index('# 交互输入端口', TEXT.index('module_dispatch()'))]
    for token in ['_action="${2:-menu}"', 'xray:install)', 'xray:uninstall)', 'nodes:show)', 'config:update_uuid)', 'config:update_shortcut)', 'argo:restart)', 'reality:show)', 'vltcp:show)', 'vlquic:restart)', 'ff:show)', 'cforigin:show)', 'socks:show)', 'http:show)']:
        assert_true(token in dispatch_body, f"module_dispatch action route missing: {token}")
    for fn in ['module_xray_install()', 'module_xray_uninstall()', 'module_nodes_show()', 'module_config_update_uuid()', 'module_config_update_shortcut()', 'module_xray_restart()', 'module_argo_restart()', 'module_show_nodes()', 'module_cforigin_show()']:
        assert_true(fn in TEXT, f"module action helper missing: {fn}")
    for marker in ['# core/global actions', '# module menu entrypoints', '# shared runtime actions', '# lifecycle actions', '# uninstall/update-port actions', '# field/config update actions', '# key/toggle actions', '# complex/specialized actions']:
        assert_true(marker in dispatch_body, f"module_dispatch should be grouped for readability: {marker}")
    xray_install_body = TEXT[TEXT.index('module_xray_install()'):TEXT.index('\n}\n', TEXT.index('module_xray_install()'))]
    xray_uninstall_body = TEXT[TEXT.index('module_xray_uninstall()'):TEXT.index('\n}\n', TEXT.index('module_xray_uninstall()'))]
    config_uuid_body = TEXT[TEXT.index('module_config_update_uuid()'):TEXT.index('\n}\n', TEXT.index('module_config_update_uuid()'))]
    config_shortcut_body = TEXT[TEXT.index('module_config_update_shortcut()'):TEXT.index('\n}\n', TEXT.index('module_config_update_shortcut()'))]
    assert_true('exec_install()' not in TEXT and 'exec_install' not in xray_install_body, "xray install should call module_xray_install_core, not exec_install")
    assert_true(
        'module_xray_install_core()' in TEXT and 'install_wizard_menu' in xray_install_body and 'install_plan_menu' in TEXT,
        "xray install should enter the deployment wizard, retain the advanced plan menu, and ultimately reuse the shared install core",
    )
    assert_true('install_execute_current_plan()' in TEXT and 'module_xray_install_core' in TEXT[TEXT.index('install_execute_current_plan()'):TEXT.index('\n}\n', TEXT.index('install_execute_current_plan()'))], "install plan executor should reuse module_xray_install_core")
    assert_true('_menu_do_install()' not in TEXT and '_menu_do_install' not in xray_install_body, "xray install workflow should live in module_xray_install, not a menu helper wrapper")
    assert_true('exec_uninstall()' not in TEXT and 'exec_uninstall' not in xray_uninstall_body, "xray uninstall workflow should live in module_xray_uninstall, not a wrapper")
    assert_true('exec_update_uuid()' not in TEXT and 'exec_update_uuid' not in config_uuid_body, "config UUID workflow should live in module_config_update_uuid, not a wrapper")
    assert_true('exec_update_shortcut()' not in TEXT and 'exec_update_shortcut' not in config_shortcut_body, "config shortcut workflow should live in module_config_update_shortcut, not a wrapper")
    assert_true('_module_action_or_continue reality restart' in TEXT and '_module_action_or_continue vltcp show' in TEXT, "module menus should route representative actions through shared dispatch wrapper")


def test_single_file_module_enable_disable_actions():
    dispatch_body = TEXT[TEXT.index('module_dispatch()'):TEXT.index('# 交互输入端口', TEXT.index('module_dispatch()'))]
    for token in ['ff:enable)', 'ff:disable)', 'reality:enable)', 'vltcp:disable)', 'cforigin:enable)', 'cforigin:disable)', 'socks:enable)', 'socks:disable)', 'http:enable)', 'http:disable)']:
        assert_true(token in dispatch_body, f"module_dispatch enable/disable route missing: {token}")
    for fn in ['module_ff_enable()', 'module_ff_disable()', 'module_reality_enable()', 'module_vltcp_enable()', 'module_cforigin_enable()', 'module_cforigin_disable()', 'module_socks_enable()', 'module_socks_disable()', 'module_http_enable()', 'module_http_disable()']:
        assert_true(fn in TEXT, f"module enable/disable helper missing: {fn}")
    for body_name, mod, plan_fn in [('unified_menu_freeflow()', 'ff', 'install_plan_ff_toggle'), ('unified_menu_reality()', 'reality', 'install_plan_reality_toggle'), ('unified_menu_vltcp()', 'vltcp', 'install_plan_vltcp_toggle'), ('unified_menu_cforigin()', 'cforigin', 'install_plan_cforigin_toggle'), ('unified_menu_socks()', 'socks', 'install_plan_socks_toggle'), ('unified_menu_http()', 'http', 'install_plan_http_toggle')]:
        body = TEXT[TEXT.index(body_name):TEXT.index('\n}\n', TEXT.index(body_name))]
        assert_true('_unified_toggle_or_plan "${_runtime}"' in body and plan_fn in body, f"{body_name} runtime/install toggle should use shared toggle helper")

def test_single_file_module_uninstall_update_actions():
    dispatch_body = TEXT[TEXT.index('module_dispatch()'):TEXT.index('# 交互输入端口', TEXT.index('module_dispatch()'))]
    for token in ['ff:uninstall)', 'reality:uninstall)', 'vltcp:uninstall)', 'reality:update_port)', 'vltcp:update_port)', 'vlquic:update_port)', 'cforigin:uninstall)', 'cforigin:update_port)', 'socks:uninstall)', 'http:uninstall)', 'http:update_port)']:
        assert_true(token in dispatch_body, f"module_dispatch uninstall/update route missing: {token}")
    for fn in ['module_ff_uninstall()', 'module_reality_uninstall()', 'module_vltcp_uninstall()', 'module_reality_update_port()', 'module_vltcp_update_port()', 'module_vlquic_update_port()', 'module_cforigin_uninstall()', 'module_cforigin_update_port()', 'module_socks_uninstall()', 'module_http_uninstall()', 'module_http_update_port()', 'module_http_update_listen()']:
        assert_true(fn in TEXT, f"module uninstall/update helper missing: {fn}")
    for body_name in ['unified_menu_freeflow()', 'unified_menu_reality()', 'unified_menu_vltcp()', 'unified_menu_vlquic()', 'unified_menu_cforigin()', 'unified_menu_socks()', 'unified_menu_http()']:
        body = TEXT[TEXT.index(body_name):TEXT.index('\n}\n', TEXT.index(body_name))]
        assert_true('_menu_confirm_uninstall' in body and '_pause; return 0' in body, f"{body_name} should provide runtime uninstall closure inside the unified workbench")

def test_single_file_module_config_update_actions():
    dispatch_body = TEXT[TEXT.index('module_dispatch()'):TEXT.index('# 交互输入端口', TEXT.index('module_dispatch()'))]
    for token in ['reality:update_transport)', 'vltcp:update_listen)', 'vlquic:update_listen)', 'cforigin:update_protocol)', 'cforigin:update_path)', 'cforigin:update_listen)', 'http:update_listen)', 'http:update_auth)', 'http:update_user)', 'http:update_pass)']:
        assert_true(token in dispatch_body, f"module_dispatch config update route missing: {token}")
    for fn in ['module_reality_update_transport()', 'module_vltcp_update_listen()', 'module_vlquic_update_listen()', 'module_cforigin_update_protocol()', 'module_cforigin_update_path()', 'module_cforigin_update_listen()', 'module_http_update_auth()', 'module_http_update_user()', 'module_http_update_pass()']:
        assert_true(fn in TEXT, f"module config update helper missing: {fn}")
    for marker in ['_unified_dispatch_or_plan "${_runtime}" reality update_transport install_plan_reality_update_transport', '_unified_dispatch_or_plan "${_runtime}" vltcp update_listen install_plan_vltcp_update_listen', '_unified_dispatch_or_plan "${_runtime}" vlquic update_listen install_plan_vlquic_update_listen', '_unified_dispatch_or_plan "${_runtime}" cforigin update_protocol install_plan_cforigin_update_protocol', '_unified_dispatch_or_plan "${_runtime}" cforigin update_path install_plan_cforigin_update_path', '_unified_dispatch_or_plan "${_runtime}" cforigin update_listen install_plan_cforigin_update_listen']:
        assert_true(marker in TEXT, f"menu should route config update through shared dispatch helper: {marker}")


def test_single_file_module_argo_freeflow_actions():
    dispatch_body = TEXT[TEXT.index('module_dispatch()'):TEXT.index('# 交互输入端口', TEXT.index('module_dispatch()'))]
    for token in ['argo:enable)', 'argo:disable)', 'argo:uninstall)', 'argo:update_protocol)', 'argo:update_port)', 'argo:update_domain)', 'argo:update_auth)', 'ff:update_mode)', 'ff:update_host_or_path)', 'ff:update_port)']:
        assert_true(token in dispatch_body, f"module_dispatch Argo/FreeFlow route missing: {token}")
    for fn in ['module_argo_enable()', 'module_argo_disable()', 'module_argo_uninstall()', 'module_argo_update_protocol()', 'module_argo_update_port()', 'module_argo_update_domain()', 'module_argo_update_auth()', 'module_ff_update_mode()', 'module_ff_update_host_or_path()', 'module_ff_update_port()']:
        assert_true(fn in TEXT, f"Argo/FreeFlow action helper missing: {fn}")
    for marker in ['_unified_dispatch_or_plan "${_runtime}" argo update_protocol install_plan_argo_update_protocol', '_unified_dispatch_or_plan "${_runtime}" argo update_domain install_plan_argo_update_domain', '_unified_dispatch_or_plan "${_runtime}" argo update_auth install_plan_argo_update_auth', '_unified_dispatch_or_plan "${_runtime}" ff update_mode install_plan_ff_update_mode', '_unified_dispatch_or_plan "${_runtime}" ff update_host_or_path install_plan_ff_update_host_or_path', '_unified_dispatch_or_plan "${_runtime}" ff update_port install_plan_ff_update_port']:
        assert_true(marker in TEXT, f"unified workbench should route Argo/FreeFlow action through shared dispatch helper: {marker}")

def test_single_file_module_final_complex_actions():
    dispatch_body = TEXT[TEXT.index('module_dispatch()'):TEXT.index('# 交互输入端口', TEXT.index('module_dispatch()'))]
    for token in ['reality:update_sni)', 'reality:regenerate_keys)', 'vlquic:enable)', 'vlquic:disable)', 'vlquic:update_cert)', 'cforigin:update_cert)', 'cforigin:update_edge_port)', 'cforigin:toggle_edge_h3)', 'cforigin:update_domain)', 'socks:update_user)', 'socks:update_pass)', 'http:update_user)', 'http:update_pass)']:
        assert_true(token in dispatch_body, f"module_dispatch final complex route missing: {token}")
    for fn in ['module_reality_update_sni()', 'module_reality_regenerate_keys()', 'module_vlquic_enable()', 'module_vlquic_disable()', 'module_vlquic_update_cert()', 'module_cforigin_update_cert()', 'module_cforigin_update_edge_port()', 'module_cforigin_toggle_edge_h3()', 'module_cforigin_update_domain()', 'module_socks_update_user()', 'module_socks_update_pass()', 'module_http_update_user()', 'module_http_update_pass()']:
        assert_true(fn in TEXT, f"final complex action helper missing: {fn}")
    for marker in ['_unified_dispatch_or_plan "${_runtime}" reality update_sni install_plan_reality_update_sni', '_unified_runtime_only_fn "${_runtime}" _module_action_or_continue reality regenerate_keys', '_unified_dispatch_or_plan "${_runtime}" vlquic update_cert install_plan_vlquic_update_cert', '_unified_dispatch_or_plan "${_runtime}" cforigin update_cert install_plan_cforigin_update_cert', '_unified_dispatch_or_plan "${_runtime}" cforigin update_domain install_plan_cforigin_update_domain', '_unified_dispatch_or_plan "${_runtime}" socks update_user install_plan_socks_update_user', '_unified_dispatch_or_plan "${_runtime}" socks update_pass install_plan_socks_update_pass', '_unified_dispatch_or_plan "${_runtime}" http update_user install_plan_http_update_user', '_unified_dispatch_or_plan "${_runtime}" http update_pass install_plan_http_update_pass']:
        assert_true(marker in TEXT, f"unified workbench should route final complex action through shared helpers: {marker}")

def test_single_file_manage_shells_are_dispatch_only():
    assert_true(TEXT.count('unified_menu_') >= 7, "closed-loop refactor should consolidate menus into unified workbenches")
    for legacy in ['manage_argo()', 'manage_freeflow()', 'manage_reality()', 'manage_vltcp()', 'manage_vlquic()', 'manage_cforigin()', 'manage_socks()', 'install_plan_manage_argo()', 'install_plan_manage_freeflow()', 'install_plan_manage_reality()', 'install_plan_manage_vltcp()', 'install_plan_manage_vlquic()', 'install_plan_manage_cforigin()', 'install_plan_manage_socks()']:
        assert_true(legacy not in TEXT, f"legacy wrapper should be removed after shrink phase: {legacy}")
    for legacy_ask in ['ask_argo_mode()', 'ask_argo_protocol()', 'ask_freeflow_mode()', 'ask_reality_mode()', 'ask_vltcp_mode()', 'ask_socks_mode()', 'ask_cforigin_mode()', 'ask_vlquic_mode()', 'ask_xpad_mode()']:
        assert_true(legacy_ask not in TEXT, f"legacy ask helper should be removed after shrink phase: {legacy_ask}")


def test_single_file_menu_render_helpers():
    assert_true('_menu_print_action()' in TEXT and '_menu_print_back()' in TEXT, "menu render should use shared action/back helpers")
    for body_name in ['unified_menu_argo()', 'unified_menu_freeflow()', 'unified_menu_reality()', 'unified_menu_vltcp()', 'unified_menu_vlquic()', 'unified_menu_cforigin()', 'unified_menu_socks()', 'unified_menu_http()']:
        body = TEXT[TEXT.index(body_name):TEXT.index('\n}\n', TEXT.index(body_name))]
        assert_true('_menu_print_action' in body, f"{body_name} should use shared action renderer")
        assert_true('_menu_print_back' in body, f"{body_name} should use shared back renderer")
        assert_true('_unified_render_mode_header' in body, f"{body_name} should print the unified mode header")

def test_single_file_module_transaction_helpers():
    helper_area = TEXT[TEXT.index('_module_disable_commit()'):TEXT.index('# ==============================================================================', TEXT.index('_module_disable_commit()'))]
    assert_true('_module_enable_commit()' in helper_area and '_module_apply_if_enabled()' in helper_area, "module transaction helpers missing")
    for body_name in ['unified_menu_freeflow()', 'unified_menu_reality()', 'unified_menu_vltcp()', 'unified_menu_cforigin()']:
        body = TEXT[TEXT.index(body_name):TEXT.index('\n}\n', TEXT.index(body_name))]
        assert_true('_module_action_or_continue' in body or '_unified_runtime_toggle' in body, f"{body_name} live actions should route through shared dispatcher/toggle helpers")
    assert_true('_module_apply_if_enabled "${_en}"' in TEXT, "enabled-only config updates should use shared apply helper")
    assert_true('_module_persist_after_optional_apply()' in TEXT, "enabled-only update persistence should use shared optional-apply commit helper")
    for proto in ['socks', 'http', 'vltcp', 'vlquic']:
        assert_true(f'module_update_listen_action {proto}' in TEXT, f'{proto} listen wrapper/dispatcher should delegate to canonical action')
    canonical_body = TEXT[TEXT.index('module_update_listen_action()'):TEXT.index('\n}\n', TEXT.index('module_update_listen_action()'))]
    assert_true('_module_persist_after_optional_apply "${_en}"' in canonical_body, "canonical listen action should use shared optional-apply commit helper")
    for fn in ['module_reality_update_transport()', 'module_cforigin_update_protocol()', 'module_cforigin_update_path()', 'module_cforigin_update_listen()', 'module_socks_update_user()', 'module_socks_update_pass()', 'module_http_update_user()', 'module_http_update_pass()', 'module_cforigin_update_domain()']:
        body = TEXT[TEXT.index(fn):TEXT.index('\n}\n', TEXT.index(fn))]
        assert_true('_module_persist_after_optional_apply "${_en}"' in body, f"{fn} should use shared optional-apply commit helper")


def test_protocol_links_and_udp_port_input_consistency():
    vltcp = TEXT[TEXT.index('_plg_vltcp_link()'):TEXT.index('PLUGIN_EOF', TEXT.index('_plg_vltcp_link()'))]
    assert_true('encryption=none' in vltcp, "VLESS-TCP link must include encryption=none")
    vlquic = TEXT[TEXT.index('_plg_vlquic_link()'):TEXT.index('PLUGIN_EOF', TEXT.index('_plg_vlquic_link()'))]
    assert_true('extra=%%7B%%22xhttpModeH3%%22%%3Atrue%%7D' in vlquic, "VLESS-XHTTP-H3 link should encode xhttpModeH3 in XHTTP extra")
    assert_true('_menu_update_port()' in TEXT, "menu port updates should use shared helper")
    assert_true('port_mgr_random_proto()' in TEXT, "random port selection should be protocol-aware")
    assert_true('_port_input=$(port_mgr_random_proto "${_proto}")' in TEXT, "empty port input should use protocol-aware random selection")
    out = run_bash("""
        source ./xray_2go.sh
        _seq=$(mktemp)
        printf '0' > "${_seq}"
        shuf() { local n; n=$(cat "${_seq}"); n=$((n + 1)); printf '%s' "${n}" > "${_seq}"; [ "${n}" -eq 1 ] && printf '443\\n' || printf '444\\n'; }
        port_mgr_in_use() { return 1; }
        port_mgr_in_use_udp() { [ "$1" = 443 ]; }
        printf 'tcp=%s udp=%s' "$(port_mgr_random_proto tcp)" "$(port_mgr_random_proto udp)"
        rm -f "${_seq}"
    """)
    assert_true(out.strip() == 'tcp=443 udp=444', "random port selection must check TCP/UDP independently")
    assert_true('module_update_port_action vlquic udp udp' in TEXT, "VLQUIC management port input must preserve UDP conflict checks")


def test_state_schema_and_plugin_permission_hardening():
    assert_true('.ports = {"argo":18888,"ff":8080,"reality":443,"vltcp":1234,"vlquic":443,"cforigin":28888,"socks":1080,"http":1081}' in TEXT, "ports schema initialization must include cforigin, socks, and http")
    assert_true('_plugin_path_safe()' in TEXT and 'stat -c' in TEXT and '_plugin_path_safe "${PLUGIN_DIR}"' in TEXT, "plugin loader must enforce ownership/mode before source")
    assert_true('val_port "${_value}"' in TEXT and 'legacy 端口字段非法' in TEXT, "legacy port migration must validate bad values explicitly")


def test_commit_helpers_fail_closed_on_firewall_reconcile():
    for fn in ['_commit', '_module_enable_commit', '_module_disable_commit']:
        candidates = [f'{fn}_inner()', f'{fn}()']
        start = next((TEXT.index(candidate) for candidate in candidates if candidate in TEXT), None)
        assert_true(start is not None, f'{fn} function missing')
        end = TEXT.index('\n}\n', start)
        body = TEXT[start:end]
        assert_true('fw_reconcile || return 1' in body, f'{fn} implementation must fail closed if firewall reconciliation fails')


def test_socks5_module_option_and_plugin_contract():
    assert_true('_plugin_write_socks()' in TEXT and '_plugin_write_socks' in TEXT[TEXT.index('plugin_install_builtins()'):TEXT.index('# ==============================================================================', TEXT.index('plugin_install_builtins()'))], "SOCKS5 built-in plugin must be installed")
    assert_true('_MODULE_IDS="argo ff reality vltcp vlquic cforigin socks http"' in TEXT, "module registry must include socks and http")
    assert_true('socks)    printf \'SOCKS5\'' in TEXT, "SOCKS5 label missing")
    assert_true('module_summary socks' in TEXT and '_MENU_SD=$(module_summary socks)' in TEXT, "main status must summarize socks")
    assert_true('socks:menu)    unified_menu_socks runtime' in TEXT, "SOCKS5 menu must route directly to unified runtime workbench")
    for token in ['socks:enable)', 'socks:disable)', 'socks:uninstall)', 'socks:update_port)', 'socks:update_listen)', 'socks:update_auth)', 'socks:update_user)', 'socks:update_pass)', 'socks:show)']:
        assert_true(token in TEXT, f"SOCKS5 dispatch route missing: {token}")
    for fn in ['module_socks_enable()', 'module_socks_disable()', 'module_socks_uninstall()', 'module_socks_update_port()', 'module_socks_update_listen()', 'module_socks_update_auth()', 'module_socks_update_user()', 'module_socks_update_pass()']:
        assert_true(fn in TEXT, f"SOCKS5 helper missing: {fn}")
    assert_true('"socks":   1080' in TEXT and '"socks": {' in TEXT, "state schema must include socks port/config")
    socks_plugin = TEXT[TEXT.index('_plugin_write_socks()'):TEXT.index('_plugin_write_cforigin()', TEXT.index('_plugin_write_socks()'))]
    for token in ['_plg_socks_inbound()', 'protocol:"socks"', 'auth:"password"', 'accounts:[{user:$user, pass:$pass}]', '_plg_socks_ports()', '_plg_socks_link()']:
        assert_true(token in socks_plugin, f"SOCKS5 plugin token missing: {token}")
    assert_true('module_update_port_action socks tcp' in TEXT, "SOCKS5 port update must use TCP conflict checks")


def test_socks5_link_is_generated_and_displayed():
    assert_true("grep -E '^(vless|trojan|socks|http)://'" in TEXT, "node output must include v2rayN-compatible proxy links, not only vless links")
    socks_plugin = TEXT[TEXT.index('_plugin_write_socks()'):TEXT.index('_plugin_write_cforigin()', TEXT.index('_plugin_write_socks()'))]
    assert_true("socks://%s@%s:%s#SOCKS5" in socks_plugin, "SOCKS plugin should generate v2rayN-compatible socks:// base64(user:pass) links")
    assert_true("base64" in socks_plugin and "tr -d '=\\n'" in socks_plugin, "SOCKS credentials must be URL-safe base64(user:pass) without padding")
    assert_true('protocol:"socks"' in socks_plugin and 'auth:"password"' in socks_plugin, "SOCKS inbound should follow reference socks password-auth implementation")


def test_http_proxy_module_option_and_plugin_contract():
    assert_true('_plugin_write_http()' in TEXT and '_plugin_write_http' in TEXT[TEXT.index('plugin_install_builtins()'):TEXT.index('# ==============================================================================', TEXT.index('plugin_install_builtins()'))], "HTTP proxy built-in plugin must be installed")
    assert_true('http:menu)     unified_menu_http runtime' in TEXT, "HTTP proxy menu must route directly to unified runtime workbench")
    for token in ['http:enable)', 'http:disable)', 'http:uninstall)', 'http:update_port)', 'http:update_listen)', 'http:update_auth)', 'http:update_user)', 'http:update_pass)', 'http:show)']:
        assert_true(token in TEXT, f"HTTP proxy dispatch route missing: {token}")
    assert_true('"http":    1081' in TEXT and '"http": {' in TEXT, "state schema must include HTTP proxy port/config")
    http_plugin = TEXT[TEXT.index('_plugin_write_http()'):TEXT.index('_plugin_write_cforigin()', TEXT.index('_plugin_write_http()'))]
    for token in ['_plg_http_inbound()', 'protocol:"http"', 'users:[{user:$user, pass:$pass}]', 'allowTransparent:false', 'userLevel:0', '_plg_http_ports()', '_plg_http_link()']:
        assert_true(token in http_plugin, f"HTTP proxy plugin token missing: {token}")
    assert_true('HTTP 代理为明文 TCP 协议' in TEXT, "HTTP proxy should warn that the inbound is unencrypted")


def test_install_plan_menu_is_advanced_install_entry():
    assert_true('install_plan_reset_defaults()' in TEXT, "install plan reset helper missing")
    assert_true('install_plan_render_summary()' in TEXT, "install plan summary renderer missing")
    assert_true('install_plan_validate()' in TEXT, "install plan validator missing")
    assert_true('install_execute_current_plan()' in TEXT, "shared install executor missing")
    assert_true('install_plan_menu()' in TEXT, "install plan menu missing")
    for fn in ['unified_menu_argo()', 'unified_menu_freeflow()', 'unified_menu_reality()', 'unified_menu_vltcp()', 'unified_menu_socks()', 'unified_menu_http()', 'unified_menu_vlquic()', 'unified_menu_cforigin()']:
        assert_true(fn in TEXT, f"unified install/runtime workbench missing: {fn}")
    body = TEXT[TEXT.index('module_xray_install()'):TEXT.index('\n}\n', TEXT.index('module_xray_install()'))]
    assert_true('install_plan_reset_defaults' in body, "module_xray_install should initialize the draft plan")
    assert_true('install_wizard_menu' in body, "first install should enter the deployment wizard")
    assert_true('install_plan_menu' not in body, "advanced install plan must not be the default first-install entry")
    for forbidden in ['ask_argo_mode', 'ask_freeflow_mode', 'ask_reality_mode', 'ask_vltcp_mode', 'ask_socks_mode', 'ask_vlquic_mode', 'ask_cforigin_mode']:
        assert_true(forbidden not in body, f"default install entry should not directly chain {forbidden}")
    plan_menu = TEXT[TEXT.index('install_plan_menu()'):TEXT.index('\n}\n', TEXT.index('install_plan_menu()'))]
    for marker in ['1) unified_menu_argo install', '2) unified_menu_freeflow install', '3) unified_menu_reality install', '4) unified_menu_vltcp install', '5) unified_menu_socks install', '6) unified_menu_vlquic install', '7) unified_menu_cforigin install', '10) install_plan_validate', '11)', '12) unified_menu_http install', 'install_execute_current_plan && return 0']:
        assert_true(marker in plan_menu, f"advanced install plan route missing: {marker}")


def test_deployment_wizard_gates_argo_required_inputs():
    assert_true('install_wizard_argo()' in TEXT, "Argo deployment wizard function missing")
    wizard_argo = TEXT.split('install_wizard_argo() {', 1)[1].split(chr(10) + '}' + chr(10), 1)[0]
    for marker in ['install_plan_reset_defaults', 'install_plan_argo_toggle', 'install_plan_argo_update_protocol', 'install_wizard_require_argo_domain', 'install_wizard_require_argo_auth', 'install_plan_argo_update_auth_protocol', 'install_wizard_confirm']:
        assert_true(marker in wizard_argo, f"Argo wizard must include required step: {marker}")
    for marker in ['install_plan_argo_update_domain', 'install_plan_argo_update_auth', 'install_execute_current_plan']:
        assert_true(marker in TEXT, f"Argo required-input helper missing: {marker}")
    assert_true('install_wizard_confirm' in wizard_argo, "Argo wizard should show a final confirmation step")


def test_deployment_wizard_exposes_recommended_paths():
    assert_true('install_wizard_menu()' in TEXT, "first-install deployment wizard function missing")
    wizard = TEXT.split('install_wizard_menu() {', 1)[1].split(chr(10) + '}' + chr(10), 1)[0]
    for marker in ['install_wizard_render', 'install_wizard_reality', 'install_wizard_argo', 'install_plan_menu']:
        assert_true(marker in wizard, f"wizard route missing: {marker}")
    for marker in ['VLESS + Reality TCP', 'Argo Tunnel', '高级自定义部署']:
        assert_true(marker in TEXT, f"wizard option label missing: {marker}")



def test_recommended_wizard_paths_reset_to_single_plan():
    reality = TEXT.split('install_wizard_reality() {', 1)[1].split(chr(10) + '}' + chr(10), 1)[0]
    argo = TEXT.split('install_wizard_argo() {', 1)[1].split(chr(10) + '}' + chr(10), 1)[0]
    assert_true('preset_apply_reality_tcp_default' in reality, "Reality wizard should apply the single-entry preset")
    assert_true('install_plan_reset_defaults' in argo, "Argo wizard should reset a cancelled/previous draft before collecting fields")


def test_install_plan_field_level_submenus_exist_for_common_modules():
    for fn in ['install_plan_argo_toggle()', 'install_plan_argo_update_protocol()', 'install_plan_argo_update_port()', 'install_plan_argo_update_domain()', 'install_plan_argo_update_auth()', 'install_plan_argo_toggle_xpad()', 'install_plan_ff_toggle()', 'install_plan_ff_update_mode()', 'install_plan_ff_update_port()', 'install_plan_ff_update_host_or_path()', 'install_plan_ff_toggle_xpad()', 'install_plan_reality_toggle()', 'install_plan_reality_update_port()', 'install_plan_reality_update_sni()', 'install_plan_reality_update_transport()', 'install_plan_reality_toggle_xpad()', 'install_plan_vltcp_toggle()', 'install_plan_vltcp_update_port()', 'install_plan_vltcp_update_listen()', 'install_plan_socks_toggle()', 'install_plan_socks_update_port()', 'install_plan_socks_update_listen()', 'install_plan_socks_update_user()', 'install_plan_socks_update_pass()', 'install_plan_http_toggle()', 'install_plan_http_update_port()', 'install_plan_http_update_listen()', 'install_plan_http_update_user()', 'install_plan_http_update_pass()', 'install_plan_vlquic_toggle()', 'install_plan_vlquic_update_port()', 'install_plan_vlquic_update_listen()', 'install_plan_vlquic_update_cert()', 'install_plan_cforigin_toggle()', 'install_plan_cforigin_update_protocol()', 'install_plan_cforigin_update_domain()', 'install_plan_cforigin_update_path()', 'install_plan_cforigin_update_edge_port()', 'install_plan_cforigin_update_origin_port()', 'install_plan_cforigin_update_listen()', 'install_plan_cforigin_toggle_edge_h3()', 'install_plan_cforigin_update_cert()']:
        assert_true(fn in TEXT, f"field-level install helper missing: {fn}")
    for body_name, marker in [('unified_menu_argo()', 'Argo 闭环工作台'), ('unified_menu_freeflow()', 'FreeFlow 闭环工作台'), ('unified_menu_reality()', 'Reality 闭环工作台'), ('unified_menu_vltcp()', 'VLESS-TCP 闭环工作台'), ('unified_menu_vlquic()', 'VLESS-XHTTP-H3 闭环工作台'), ('unified_menu_cforigin()', 'CF Origin 闭环工作台'), ('unified_menu_socks()', 'SOCKS5 闭环工作台'), ('unified_menu_http()', 'HTTP 代理闭环工作台')]:
        body = TEXT[TEXT.index(body_name):TEXT.index('\n}\n', TEXT.index(body_name))]
        assert_true(marker in body and '_runtime=0' in body, f"unified workbench marker missing for {body_name}")

def test_interactive_menu_copy_is_guided_and_consistent():
    assert_true('_menu_print_action 0 "返回上一级"' in TEXT, "submenu back label should say return to upper level")
    assert_true('Xray-2go 控制台' in TEXT, "main menu title should be localized")
    assert_true('开始部署（快速向导）' in TEXT, "main menu install copy should name the guided deployment entry")
    assert_true('快速部署向导' in TEXT and '高级自定义部署' in TEXT, "first-install path should expose guided and advanced modes")
    for token in ['进入 Reality 配置页', '运行安装前检查', '开始安装', 'prompt "请选择部署方案 (0-3): " _c', '确认开始部署？(Y/n): ', '请选择操作 $( [ "${_runtime}" -eq 1 ] && printf', '返回上一级']:
        assert_true(token in TEXT, f"interactive menu copy token missing: {token}")


def test_cli_reality_tcp_preset_entry_exists_and_uses_shared_executor():
    for fn in ['usage()', 'parse_args()', 'cli_install()', 'cli_dispatch()', 'preset_apply_reality_tcp_default()', 'reality_pick_default_tcp_port()']:
        assert_true(fn in TEXT, f"CLI helper missing: {fn}")
    parse_body = TEXT[TEXT.index('parse_args()'):TEXT.index('\n}\n', TEXT.index('parse_args()'))]
    for token in ['_CLI_ACTION="menu"', '_CLI_REALITY_PORT=""', '[ "$#" -eq 0 ] && return 0', 'reality)', '-p)', '-p 需要端口值', '未知参数: $1']:
        assert_true(token in parse_body, f"parse_args token missing: {token}")
    cli_install_body = TEXT[TEXT.index('cli_install()'):TEXT.index('\n}\n', TEXT.index('cli_install()'))]
    for token in ['preset_apply_reality_tcp_default', '_CLI_REALITY_PORT', 'install_execute_current_plan']:
        assert_true(token in cli_install_body, f"cli_install token missing: {token}")
    preset_body = TEXT[TEXT.index('preset_apply_reality_tcp_default()'):TEXT.index('\n}\n', TEXT.index('preset_apply_reality_tcp_default()'))]
    for token in ['local _port _explicit_port', 'val_port "${_explicit_port}"', '.reality.enabled = true', '.reality.network = "tcp"', '.argo.enabled = false', '.ff.enabled = false', '.vltcp.enabled = false', '.socks.enabled = false', '.vlquic.enabled = false', '.cforigin.enabled = false']:
        assert_true(token in preset_body, f"reality tcp preset missing: {token}")
    assert_true('reality_pick_default_tcp_port' in preset_body and '.ports.reality = ($p|tonumber)' in preset_body, "reality preset should set port through helper or explicit override")
    pick_body = TEXT[TEXT.index('reality_pick_default_tcp_port()'):TEXT.index('\n}\n', TEXT.index('reality_pick_default_tcp_port()'))]
    for token in ['local _preferred=443', 'port_mgr_in_use "${_preferred}"', 'port_mgr_random_proto tcp', '自动改用随机端口']:
        assert_true(token in pick_body, f"reality default port helper token missing: {token}")
    main_body = TEXT[TEXT.index('main()'):TEXT.index('if [ "${BASH_SOURCE[0]}" = "$0" ]; then', TEXT.index('main()'))]
    assert_true('cli_dispatch "$@"' in main_body, "main should route through cli_dispatch")
    out = run_bash("""
        source ./xray_2go.sh
        st_init
        parse_args reality -p 2443
        printf 'alias_action=%s port_override=%s\n' "${_CLI_ACTION}" "${_CLI_REALITY_PORT}"
        preset_apply_reality_tcp_default "${_CLI_REALITY_PORT}"
        printf 'argo=%s reality=%s net=%s ff=%s socks=%s vlquic=%s cforigin=%s port=%s\n' \
            "$(st_get '.argo.enabled')" "$(st_get '.reality.enabled')" "$(st_get '.reality.network')" \
            "$(st_get '.ff.enabled')" "$(st_get '.socks.enabled')" "$(st_get '.vlquic.enabled')" \
            "$(st_get '.cforigin.enabled')" "$(port_of reality)"
    """)
    assert_true('alias_action=install port_override=2443' in out, "reality -p should enter install mode and persist explicit port override")
    assert_true('reality=true net=tcp' in out and 'port=2443' in out, "reality tcp preset should apply the explicit port override")


def test_reality_preset_auto_random_port_when_443_busy():
    out = run_bash("""
        source ./xray_2go.sh
        st_init
        port_mgr_in_use() { [ "$1" = 443 ]; }
        port_mgr_random_proto() { printf '23456'; }
        preset_apply_reality_tcp_default
        printf 'port=%s\n' "$(port_of reality)"
    """)
    assert_true('port=23456' in out, "reality preset should auto-switch to random high port when 443 is busy")


def test_cli_reality_port_option_requires_valid_value():
    out = run_bash("""
        source ./xray_2go.sh
        parse_args reality -p 2443
        printf 'ok=%s\n' "${_CLI_REALITY_PORT}"
    """)
    assert_true('ok=2443' in out, 'reality -p should accept a valid explicit port')

    try:
        run_bash("source ./xray_2go.sh; parse_args reality -p")
        raise AssertionError('parse_args reality -p should fail without a value')
    except subprocess.CalledProcessError as e:
        assert_true('-p 需要端口值' in e.stdout, 'reality -p without value should fail with a clear error')

    try:
        run_bash("source ./xray_2go.sh; parse_args reality -p abc")
        raise AssertionError('parse_args reality -p abc should fail')
    except subprocess.CalledProcessError as e:
        assert_true('非法端口' in e.stdout or '端口' in e.stdout, 'reality -p should validate port format')


def test_socks_runtime_actions_have_single_canonical_owner():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                "source ./xray_2go.sh; "
                "set -e; "
                "mkdir -p \"${WORK_DIR}\"; "
                "st_init; "
                "config_apply() { :; }; "
                "st_persist() { :; }; "
                "fw_reconcile() { :; }; "
                "config_print_nodes() { :; }; "
                "module_socks_action enable; "
                "printf 'after_enable=%s\\n' \"$(st_get '.socks.enabled')\"; "
                "module_socks_action disable; "
                "printf 'after_disable=%s\\n' \"$(st_get '.socks.enabled')\"; "
                "module_socks_action() { printf 'dispatcher_action=%s\\n' \"$1\"; }; "
                "module_dispatch socks enable",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"canonical SOCKS action failed: {cp.stdout}")
    assert_true("after_enable=true" in cp.stdout, "canonical SOCKS action must enable the module")
    assert_true("after_disable=false" in cp.stdout, "canonical SOCKS action must disable the module")
    assert_true("dispatcher_action=enable" in cp.stdout, "dispatcher must route SOCKS enable to canonical action")


def test_runtime_port_actions_have_single_canonical_owner():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                "source ./xray_2go.sh; "
                "set -e; "
                "mkdir -p \"${WORK_DIR}\"; "
                "st_init; "
                "config_apply() { :; }; "
                "st_persist() { :; }; "
                "fw_reconcile() { :; }; "
                "config_print_nodes() { :; }; "
                "port_mgr_in_use() { return 1; }; "
                "prompt() { printf -v \"$2\" '%s' 2443; }; "
                "module_update_port_action reality tcp; "
                "printf 'reality=%s\\n' \"$(port_of reality)\"; "
                "module_update_port_action() { printf 'dispatcher_port=%s/%s\\n' \"$1\" \"$2\"; }; "
                "module_dispatch vltcp update_port",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"canonical runtime port action failed: {cp.stdout}")
    assert_true("reality=2443" in cp.stdout, "canonical port action must update the requested port")
    assert_true("dispatcher_port=vltcp/tcp" in cp.stdout, "dispatcher must route update_port to canonical action")


def test_runtime_listen_actions_have_single_canonical_owner():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                "source ./xray_2go.sh; "
                "set -e; "
                "mkdir -p \"${WORK_DIR}\"; "
                "st_init; "
                "config_apply() { :; }; "
                "st_persist() { :; }; "
                "prompt() { printf -v \"$2\" '%s' 127.0.0.1; }; "
                "module_update_listen_action vltcp; "
                "printf 'vltcp=%s\\n' \"$(st_get '.vltcp.listen')\"; "
                "module_update_listen_action() { printf 'dispatcher_listen=%s\\n' \"$1\"; }; "
                "module_dispatch socks update_listen",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"canonical runtime listen action failed: {cp.stdout}")
    assert_true("vltcp=127.0.0.1" in cp.stdout, "canonical listen action must update the requested address")
    assert_true("dispatcher_listen=socks" in cp.stdout, "dispatcher must route update_listen to canonical action")


def test_runtime_show_actions_have_single_canonical_owner():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                "source ./xray_2go.sh; "
                "set -e; "
                "config_print_nodes() { printf 'nodes\\n'; }; "
                "cforigin_print_cloudflare_hint() { printf 'cforigin_hint\\n'; }; "
                "module_show_action cforigin; "
                "module_show_action() { printf 'dispatcher_show=%s\\n' \"$1\"; }; "
                "module_dispatch reality show",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"canonical runtime show action failed: {cp.stdout}")
    assert_true("nodes" in cp.stdout and "cforigin_hint" in cp.stdout, "canonical show action must preserve CF Origin hint output")
    assert_true("dispatcher_show=reality" in cp.stdout, "dispatcher must route show to canonical action")


def test_runtime_argo_field_actions_have_single_canonical_owner():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                "source ./xray_2go.sh; "
                "set -e; "
                "module_argo_update_action() { printf 'argo_action=%s\\n' \"$1\"; }; "
                "module_dispatch argo update_protocol; "
                "module_dispatch argo update_auth_protocol; "
                "module_dispatch argo update_trojan_password; "
                "module_dispatch argo update_domain; "
                "module_dispatch argo update_auth",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"Argo field dispatcher failed: {cp.stdout}")
    for action in ["protocol", "auth_protocol", "trojan_password", "domain", "auth"]:
        assert_true(f"argo_action={action}" in cp.stdout, f"Argo dispatcher must route {action} to canonical owner: {cp.stdout}")


def test_runtime_enable_paths_no_longer_depend_on_removed_ask_helpers():
    out = run_bash("""
        source ./xray_2go.sh
        st_init
        config_apply() { return 0; }
        st_persist() { return 0; }
        fw_reconcile() { return 0; }
        cforigin_print_cloudflare_hint() { :; }
        config_print_nodes() { :; }
        module_dispatch ff enable
        printf 'ff=%s proto=%s\n' "$(st_get '.ff.enabled')" "$(st_get '.ff.protocol')"
        module_dispatch socks enable
        printf 'socks=%s\n' "$(st_get '.socks.enabled')"
        st_set '.cforigin.domain = "example.com" | .cforigin.cert = "${WORK_DIR}/cert.pem" | .cforigin.key = "${WORK_DIR}/key.pem"' >/dev/null
        : >"${WORK_DIR}/cert.pem"
        : >"${WORK_DIR}/key.pem"
        module_dispatch cforigin enable
        printf 'cforigin=%s proto=%s path=%s\n' "$(st_get '.cforigin.enabled')" "$(st_get '.cforigin.protocol')" "$(st_get '.cforigin.path')"
        rm -f "${WORK_DIR}/cert.pem" "${WORK_DIR}/key.pem"
    """)
    assert_true('ff=true proto=ws' in out, 'ff enable should no longer depend on removed ask_* helpers and should seed default protocol')
    assert_true('socks=true' in out, 'socks enable should no longer depend on removed ask_* helpers')
    assert_true('cforigin=true proto=ws path=/origin' in out, 'cforigin enable should no longer depend on removed ask_* helpers and should seed defaults')


def test_runtime_dispatch_supports_reality_and_vltcp_update_port():
    out = run_bash("""
        source ./xray_2go.sh
        st_init
        config_apply() { return 0; }
        st_persist() { return 0; }
        fw_reconcile() { return 0; }
        prompt() { printf -v "$2" '%s' 2443; }
        module_dispatch reality update_port
        printf 'reality=%s\n' "$(port_of reality)"
        prompt() { printf -v "$2" '%s' 15555; }
        module_dispatch vltcp update_port
        printf 'vltcp=%s\n' "$(port_of vltcp)"
    """)
    assert_true('reality=2443' in out, 'runtime dispatch should support reality update_port')
    assert_true('vltcp=15555' in out, 'runtime dispatch should support vltcp update_port')


def test_install_plan_argo_auth_is_state_only_before_execution():
    out = run_bash("""
        source ./xray_2go.sh
        st_init
        rm -f "${WORK_DIR}/tunnel.json"
        prompt_secret() {
            printf '%s' '{"TunnelSecret":"abc","TunnelID":"11111111-1111-1111-1111-111111111111"}'
            printf -v "$2" '%s' '{"TunnelSecret":"abc","TunnelID":"11111111-1111-1111-1111-111111111111"}'
        }
        install_plan_argo_update_auth
        printf 'cred_b64=%s token=%s file=%s\n' "$(st_get '.argo.cred_b64')" "$(st_get '.argo.token')" "$( [ -f "${WORK_DIR}/tunnel.json" ] && printf yes || printf no )"
        rm -f "${WORK_DIR}/tunnel.json"
    """)
    assert_true('file=no' in out, 'install-plan argo auth editing must not create tunnel.json before execution')
    assert_true('cred_b64=' in out and 'token=' in out, 'install-plan argo auth should persist state fields')


def test_install_execute_current_plan_uses_state_based_argo_apply():
    m = re.search(r"install_execute_current_plan\(\) \{(?P<body>.*?)\n\}", TEXT, re.S)
    assert_true(m, 'install_execute_current_plan function missing')
    body = m.group('body')
    assert_true('argo_apply_fixed_tunnel_from_state' in body, 'install execution should use state-based argo apply path')
    assert_true('argo_apply_fixed_tunnel ||' not in body, 'install execution should not fall back to interactive argo apply path')


def test_state_get_preserves_false_and_zero_values():
    cp = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE="${_STATE_DEFAULT}"
        _st_normalize_schema >/dev/null
        st_set '.argo.enabled = false | .ports.argo = 0' >/dev/null
        printf 'enabled=%s port=%s\\n' "$(st_get '.argo.enabled')" "$(st_get '.ports.argo')"
    """)
    assert_true(cp.returncode == 0, "state probe should complete")
    assert_true("enabled=false" in cp.stdout and "port=0" in cp.stdout, "state reads must preserve false and zero")


def test_install_refresh_failure_uses_initialized_rollback_flags():
    install_start = TEXT.index("module_xray_install_core()")
    refresh = TEXT.index("plugin_refresh_runtime ||", install_start)
    declaration = TEXT.index("local _xray_was=0 _argo_was=0", install_start)
    assert_true(declaration < refresh, "install rollback flags must be initialized before plugin refresh can fail")


def test_install_plan_rejects_unconfigured_argo():
    cp = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE="${_STATE_DEFAULT}"
        _st_normalize_schema >/dev/null
        install_plan_validate
    """)
    assert_true(cp.returncode != 0, "an enabled but unconfigured Argo plan must fail validation")
    assert_true("Argo" in cp.stdout and ("域名" in cp.stdout or "token" in cp.stdout), "Argo validation should explain the missing configuration")


def test_install_execute_fails_when_argo_apply_fails():
    cp = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE="${_STATE_DEFAULT}"
        _st_normalize_schema >/dev/null
        st_set '.argo.enabled = true | .argo.domain = "origin.example.com" | .argo.token = "aaaaaaaaaaaaaaaaaaaa"' >/dev/null
        install_plan_validate() { return 0; }
        module_xray_install_core() { return 0; }
        st_persist() { return 0; }
        argo_apply_fixed_tunnel_from_state() { return 1; }
        config_print_nodes() { return 0; }
        cforigin_print_cloudflare_hint() { return 0; }
        install_execute_current_plan
    """)
    assert_true(cp.returncode != 0, "install must fail when selected Argo application fails")


def test_argo_enable_rolls_back_on_start_failure():
    cp = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE="${_STATE_DEFAULT}"
        _st_normalize_schema >/dev/null
        st_set '.argo.enabled = false' >/dev/null
        download_cloudflared() { return 0; }
        config_apply() { return 0; }
        svc_apply_tunnel() { return 0; }
        svc_reload_daemon() { return 0; }
        svc_exec_mut() { [ "$1" = "start" ] && return 1; return 0; }
        st_persist() { return 0; }
        fw_reconcile() { return 0; }
        module_argo_enable
        rc=$?
        printf 'module-rc=%s enabled=%s\\n' "$rc" "$(st_get '.argo.enabled')"
        exit 0
    """)
    assert_true("module-rc=0" not in cp.stdout, "Argo start failure must not return success")
    assert_true("enabled=false" in cp.stdout, "Argo state must roll back after start failure")


def test_argo_enable_health_failure_rolls_back():
    cp = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE="${_STATE_DEFAULT}"
        _st_normalize_schema >/dev/null
        st_set '.argo.enabled = false' >/dev/null
        download_cloudflared() { return 0; }
        config_apply() { return 0; }
        svc_apply_tunnel() { return 0; }
        svc_reload_daemon() { return 0; }
        svc_exec_mut() { return 0; }
        svc_verify_health() { printf 'health-called\\n'; return 1; }
        st_persist() { return 0; }
        fw_reconcile() { return 0; }
        module_argo_enable
        rc=$?
        printf 'module-rc=%s enabled=%s\\n' "$rc" "$(st_get '.argo.enabled')"
        exit 0
    """)
    assert_true(cp.returncode == 0, f"Argo health rollback probe process failed: {cp.stdout}")
    assert_true("health-called" in cp.stdout, "Argo enable must verify Tunnel health after start")
    assert_true("module-rc=1" in cp.stdout and "enabled=false" in cp.stdout, "health failure must roll back Argo enable")


def test_runtime_argo_enable_restores_cross_artifact_state_after_start_failure():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}" "${_SVC_SYSTEMD_DIR}"
printf '#!/bin/sh\\n' > "${ARGO_BIN}"
chmod 700 "${ARGO_BIN}"
st_init >/dev/null 2>&1
st_set '.argo.enabled = false' >/dev/null
st_persist >/dev/null 2>&1
printf 'old-config' > "${CONFIG_FILE}"
printf 'old-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_TUNNEL}.service"
printf 'old-env' > "${_ARGO_ENV_FILE}"
printf 'old-tunnel' > "${WORK_DIR}/tunnel.yml"
printf 'nft:1080/tcp\\n' > "${_FW_RULES_FILE}"
printf '1080\\n' > "${_FW_PORTS_FILE}"
_SERVICE_ACTIVE=0
_SERVICE_ENABLED=0
svc_exec() { [ "$1" = status ] && [ "${_SERVICE_ACTIVE}" = 1 ]; }
svc_is_enabled() { [ "${_SERVICE_ENABLED}" = 1 ]; }
config_apply() {
    printf 'new-config' > "${CONFIG_FILE}"
    printf 'iptables:9999/tcp\\n' > "${_FW_RULES_FILE}"
    printf '9999\\n' > "${_FW_PORTS_FILE}"
    return 0
}
svc_apply_tunnel() {
    printf 'new-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_TUNNEL}.service"
    printf 'new-env' > "${_ARGO_ENV_FILE}"
    printf 'new-tunnel' > "${WORK_DIR}/tunnel.yml"
    return 0
}
svc_reload_daemon() { return 0; }
fw_reconcile() { return 0; }
svc_exec_mut() {
    case "$1" in
        enable) _SERVICE_ENABLED=1; return 0 ;;
        disable) _SERVICE_ENABLED=0; return 0 ;;
        start) _SERVICE_ACTIVE=1; return 1 ;;
        stop) _SERVICE_ACTIVE=0; return 0 ;;
    esac
    return 1
}
module_argo_enable >/dev/null 2>&1
_rc=$?
printf 'rc=%s memory=%s state=%s config=%s service=%s env=%s tunnel=%s fw=%s ports=%s active=%s enabled=%s\\n' \\
    "${_rc}" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.argo.enabled')" \\
    "$(jq -c . "${STATE_FILE}")" \\
    "$(cat "${CONFIG_FILE}")" \\
    "$(cat "${_SVC_SYSTEMD_DIR}/${_SVC_TUNNEL}.service")" \\
    "$(cat "${_ARGO_ENV_FILE}")" \\
    "$(cat "${WORK_DIR}/tunnel.yml")" \\
    "$(cat "${_FW_RULES_FILE}")" \\
    "$(cat "${_FW_PORTS_FILE}")" \\
    "${_SERVICE_ACTIVE}" "${_SERVICE_ENABLED}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"Argo enable rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=false state={" in cp.stdout
        and '"enabled":false' in cp.stdout
        and "config=old-config service=old-service env=old-env tunnel=old-tunnel fw=nft:1080/tcp ports=1080 active=0 enabled=0" in cp.stdout,
        f"failed Argo start must restore state, artifacts and service status: {cp.stdout}",
    )


def test_transaction_interrupt_restores_files_and_state():
    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                "source ./xray_2go.sh\n"
                "mkdir -p \"${WORK_DIR}\"\n"
                "printf 'old-config\\n' > \"${CONFIG_FILE}\"\n"
                "_G_STATE=\"${_STATE_DEFAULT}\"\n"
                "_st_normalize_schema >/dev/null\n"
                "st_set '.argo.enabled = false' >/dev/null\n"
                "st_persist >/dev/null\n"
                "_interrupt_probe() {\n"
                "    printf 'new-config\\n' > \"${CONFIG_FILE}\"\n"
                "    st_set '.argo.enabled = true' >/dev/null\n"
                "    kill -INT $$\n"
                "}\n"
                "_transaction_run '中断测试' _interrupt_probe\n",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )
        config = (sandbox.root / "etc/xray2go/config.json").read_text(encoding="utf-8")
        state = (sandbox.root / "etc/xray2go/state.json").read_text(encoding="utf-8")
    assert_true(cp.returncode == 130, f"SIGINT must exit with 130: {cp.stdout}")
    assert_true(config.startswith("old-config") and config.endswith("\n"), f"SIGINT must restore config artifact: {config!r}")
    assert_true('"enabled":false' in state.replace(" ", ""), f"SIGINT must restore persisted state: {state}")


def test_concurrent_transactions_serialize_failure_and_commit():
    with XraySandbox() as sandbox:
        work_dir = sandbox.root / "etc/xray2go"
        work_dir.mkdir(parents=True, exist_ok=True)
        (work_dir / "config.json").write_text("old-config\\n", encoding="utf-8")
        command = (
            "source ./xray_2go.sh\n"
            "mkdir -p \"${WORK_DIR}\"\n"
            "_G_STATE=\"${_STATE_DEFAULT}\"\n"
            "_st_normalize_schema >/dev/null\n"
            "_probe() {\n"
            "    printf '%s-start\\n' \"${LABEL}\" >> \"${WORK_DIR}/timeline\"\n"
            "    printf '%s\\n' \"${LABEL}\" > \"${CONFIG_FILE}\"\n"
            "    sleep 0.4\n"
            "    printf '%s-end\\n' \"${LABEL}\" >> \"${WORK_DIR}/timeline\"\n"
            "    return \"${RESULT}\"\n"
            "}\n"
            "_transaction_run \"${LABEL}\" _probe\n"
        )
        env_a = sandbox.environment()
        env_a.update({"LABEL": "A", "RESULT": "1"})
        env_b = sandbox.environment()
        env_b.update({"LABEL": "B", "RESULT": "0"})
        proc_a = subprocess.Popen(
            ["bash", "-lc", command],
            cwd=ROOT,
            env=env_a,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        time.sleep(0.05)
        proc_b = subprocess.Popen(
            ["bash", "-lc", command],
            cwd=ROOT,
            env=env_b,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        out_a, _ = proc_a.communicate(timeout=20)
        out_b, _ = proc_b.communicate(timeout=20)
        timeline = (work_dir / "timeline").read_text(encoding="utf-8").splitlines()
        final_config = (work_dir / "config.json").read_text(encoding="utf-8")
    assert_true(proc_a.returncode == 1, f"failed transaction must return failure: {out_a}")
    assert_true(proc_b.returncode == 0, f"waiting transaction must commit successfully: {out_b}")
    assert_true(timeline in (["A-start", "A-end", "B-start", "B-end"], ["B-start", "B-end", "A-start", "A-end"]), f"transactions must not overlap: {timeline}")
    assert_true(final_config.startswith("B") and final_config.endswith("\n"), f"later successful transaction must own final artifact: {final_config!r}")


def test_runtime_argo_disable_restores_service_state_after_commit_failure():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}" "${_SVC_SYSTEMD_DIR}"
st_init >/dev/null 2>&1
st_set '.argo.enabled = true' >/dev/null
st_persist >/dev/null 2>&1
printf 'old-config' > "${CONFIG_FILE}"
printf 'old-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_TUNNEL}.service"
printf 'old-env' > "${_ARGO_ENV_FILE}"
printf 'old-tunnel' > "${WORK_DIR}/tunnel.yml"
printf 'nft:1080/tcp\\n' > "${_FW_RULES_FILE}"
printf '1080\\n' > "${_FW_PORTS_FILE}"
_SERVICE_ACTIVE=1
_SERVICE_ENABLED=1
svc_exec() { [ "$1" = status ] && [ "${_SERVICE_ACTIVE}" = 1 ]; }
svc_is_enabled() { [ "${_SERVICE_ENABLED}" = 1 ]; }
svc_exec_mut() {
    case "$1" in
        disable) _SERVICE_ENABLED=0; return 0 ;;
        stop) _SERVICE_ACTIVE=0; return 0 ;;
        enable) _SERVICE_ENABLED=1; return 0 ;;
        start) _SERVICE_ACTIVE=1; return 0 ;;
    esac
    return 1
}
config_apply() {
    printf 'new-config' > "${CONFIG_FILE}"
    return 1
}
fw_reconcile() { return 0; }
module_argo_disable >/dev/null 2>&1
_rc=$?
printf 'rc=%s memory=%s state=%s config=%s service=%s env=%s tunnel=%s fw=%s ports=%s active=%s enabled=%s\\n' \\
    "${_rc}" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.argo.enabled')" \\
    "$(jq -c . "${STATE_FILE}")" \\
    "$(cat "${CONFIG_FILE}")" \\
    "$(cat "${_SVC_SYSTEMD_DIR}/${_SVC_TUNNEL}.service")" \\
    "$(cat "${_ARGO_ENV_FILE}")" \\
    "$(cat "${WORK_DIR}/tunnel.yml")" \\
    "$(cat "${_FW_RULES_FILE}")" \\
    "$(cat "${_FW_PORTS_FILE}")" \\
    "${_SERVICE_ACTIVE}" "${_SERVICE_ENABLED}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"Argo disable rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=true state={" in cp.stdout
        and '"enabled":true' in cp.stdout
        and "config=old-config service=old-service env=old-env tunnel=old-tunnel fw=nft:1080/tcp ports=1080 active=1 enabled=1" in cp.stdout,
        f"failed Argo disable must restore state, artifacts and service status: {cp.stdout}",
    )


def test_runtime_argo_uninstall_restores_deleted_artifacts_after_commit_failure():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}" "${_SVC_SYSTEMD_DIR}"
printf 'old-argo' > "${ARGO_BIN}"
chmod 700 "${ARGO_BIN}"
st_init >/dev/null 2>&1
st_set '.argo.enabled = true | .argo.domain = "old.example.com"' >/dev/null
st_persist >/dev/null 2>&1
printf 'old-config' > "${CONFIG_FILE}"
printf 'old-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_TUNNEL}.service"
printf 'old-env' > "${_ARGO_ENV_FILE}"
printf 'old-yml' > "${WORK_DIR}/tunnel.yml"
printf 'old-json' > "${WORK_DIR}/tunnel.json"
printf 'nft:1080/tcp\\n' > "${_FW_RULES_FILE}"
printf '1080\\n' > "${_FW_PORTS_FILE}"
_SERVICE_ACTIVE=1
_SERVICE_ENABLED=1
svc_exec() { [ "$1" = status ] && [ "${_SERVICE_ACTIVE}" = 1 ]; }
svc_is_enabled() { [ "${_SERVICE_ENABLED}" = 1 ]; }
svc_exec_mut() {
    case "$1" in
        disable) _SERVICE_ENABLED=0; return 0 ;;
        stop) _SERVICE_ACTIVE=0; return 0 ;;
        enable) _SERVICE_ENABLED=1; return 0 ;;
        start) _SERVICE_ACTIVE=1; return 0 ;;
    esac
    return 1
}
is_systemd() { return 0; }
systemctl() { return 0; }
config_apply() { return 1; }
fw_reconcile() { return 0; }
module_argo_uninstall >/dev/null 2>&1
_rc=$?
printf 'rc=%s memory=%s state=%s argo=%s service=%s env=%s yml=%s json=%s fw=%s ports=%s active=%s enabled=%s\\n' \\
    "${_rc}" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.argo.enabled')" \\
    "$(jq -c . "${STATE_FILE}")" \\
    "$(cat "${ARGO_BIN}" 2>/dev/null || printf missing)" \\
    "$(cat "${_SVC_SYSTEMD_DIR}/${_SVC_TUNNEL}.service" 2>/dev/null || printf missing)" \\
    "$(cat "${_ARGO_ENV_FILE}" 2>/dev/null || printf missing)" \\
    "$(cat "${WORK_DIR}/tunnel.yml" 2>/dev/null || printf missing)" \\
    "$(cat "${WORK_DIR}/tunnel.json" 2>/dev/null || printf missing)" \\
    "$(cat "${_FW_RULES_FILE}")" \\
    "$(cat "${_FW_PORTS_FILE}")" \\
    "${_SERVICE_ACTIVE}" "${_SERVICE_ENABLED}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"Argo uninstall rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=true state={" in cp.stdout
        and '"enabled":true' in cp.stdout
        and "argo=old-argo service=old-service env=old-env yml=old-yml json=old-json fw=nft:1080/tcp ports=1080 active=1 enabled=1" in cp.stdout,
        f"failed Argo uninstall must restore deleted artifacts and service status: {cp.stdout}",
    )


def test_argo_domain_update_rolls_back_on_apply_failure():
    cp = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE="${_STATE_DEFAULT}"
        _st_normalize_schema >/dev/null
        st_set '.argo.enabled = true | .argo.domain = "old.example.com"' >/dev/null
        prompt() { printf -v "$2" '%s' 'new.example.com'; }
        argo_apply_fixed_tunnel_from_state() { return 1; }
        config_print_nodes() { return 0; }
        module_argo_update_domain
        rc=$?
        printf 'module-rc=%s domain=%s\\n' "$rc" "$(st_get '.argo.domain')"
        exit 0
    """)
    assert_true(cp.returncode == 0, "domain rollback probe should complete")
    assert_true("module-rc=0" not in cp.stdout, "domain update must fail when Argo apply fails")
    assert_true("domain=old.example.com" in cp.stdout, "Argo domain must roll back after apply failure")


def test_argo_domain_update_rolls_back_null_domain_type_on_apply_failure():
    cp = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE="${_STATE_DEFAULT}"
        _st_normalize_schema >/dev/null
        st_set '.argo.enabled = true | .argo.domain = null' >/dev/null
        prompt() { printf -v "$2" '%s' 'new.example.com'; }
        argo_apply_fixed_tunnel_from_state() { return 1; }
        config_print_nodes() { return 0; }
        module_argo_update_domain
        rc=$?
        printf 'module-rc=%s domain_type=%s domain=%s\\n' "$rc" "$(printf '%s' "${_G_STATE}" | jq -r '.argo.domain | type')" "$(st_get '.argo.domain')"
        exit 0
    """)
    assert_true(cp.returncode == 0, "null-domain rollback probe should complete")
    assert_true("module-rc=0" not in cp.stdout, "domain update must fail when Argo apply fails")
    assert_true("domain_type=null" in cp.stdout, "Argo domain rollback must preserve JSON null type")


def test_cforigin_plain_http_does_not_require_certificates():
    cp = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE="${_STATE_DEFAULT}"
        _st_normalize_schema >/dev/null
        st_set '.argo.enabled = false | .cforigin.enabled = true | .cforigin.domain = "origin.example.com" | .cforigin.origin_tls = false | .cforigin.cert = "" | .cforigin.key = ""' >/dev/null
        install_plan_validate
    """)
    assert_true(cp.returncode == 0, "plain HTTP CF Origin should validate without certificate files")


def test_trojan_argo_capability_is_owned_by_main_script():
    assert_true('"auth_protocol": "vless"' in TEXT, "Argo must have an explicit authentication protocol state")
    assert_true('auth_protocol' in TEXT and 'trojan' in TEXT, "main script must contain the Trojan Argo capability")
    assert_true('protocol:"trojan"' in TEXT, "main script must render a Trojan inbound")
    assert_true('trojan://' in TEXT, "main script must render a Trojan share link")
    assert_true('val_trojan_password' in TEXT, "Trojan password must have a dedicated validator")


def test_legacy_trojan_script_is_removed_after_migration():
    assert_true(not (ROOT / "xray_2go_Trojan_Socks5.sh").exists(), "legacy standalone Trojan script must not remain after migration")


def test_state_normalizes_missing_trojan_password_field():
    cp = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE='{"uuid":"56b6d850-1e42-48ef-8229-94f5d8292e54","argo":{"enabled":true,"protocol":"ws"}}'
        _st_normalize_schema >/dev/null
        printf '%s' "${_G_STATE}" | jq -e '(.argo | has("trojan_password")) and .argo.trojan_password == ""' >/dev/null
    """)
    assert_true(cp.returncode == 0, "schema normalization must add a missing Trojan password field")


def test_state_self_heals_illegal_trojan_transport_combination():
    cp = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE='{"uuid":"56b6d850-1e42-48ef-8229-94f5d8292e54","argo":{"enabled":true,"protocol":"xhttp","auth_protocol":"trojan","trojan_password":""}}'
        _st_normalize_schema >/dev/null 2>&1
        printf '%s' "${_G_STATE}" | jq -e '.argo.auth_protocol == "vless"' >/dev/null
    """)
    assert_true(cp.returncode == 0, "normalization must heal Trojan with non-WS transport back to VLESS")


def test_illegal_trojan_transport_state_does_not_lock_config_synthesis():
    cp = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE='{"uuid":"56b6d850-1e42-48ef-8229-94f5d8292e54","argo":{"enabled":true,"protocol":"xhttp","auth_protocol":"trojan","trojan_password":""}}'
        _st_normalize_schema >/dev/null 2>&1
        plugin_install_builtins >/dev/null 2>&1
        plugin_load_all >/dev/null 2>&1
        config_synthesize >/dev/null 2>&1
    """)
    assert_true(cp.returncode == 0, "healed state must not leave config synthesis fail-closed")


def test_transport_switch_is_guarded_while_trojan_auth_is_active():
    for fn in ["install_plan_argo_update_protocol", "_module_argo_update_protocol_impl"]:
        m = re.search(rf"{fn}\(\) \{{(?P<body>.*?)\n\}}", TEXT, re.S)
        assert_true(m, f"{fn} function missing")
        body = m.group("body")
        assert_true(
            "auth_protocol" in body and "trojan" in body,
            f"{fn} must refuse switching transport away from WS while Trojan auth is active",
        )


def test_runtime_argo_updates_roll_back_in_memory_state_on_apply_failure():
    # Behavioural probe: a failing fixed-tunnel apply must leave in-memory state untouched.
    out = run_bash("""
        source ./xray_2go.sh
        st_init >/dev/null 2>&1
        st_set '.argo.enabled = true | .argo.protocol = "ws" | .argo.auth_protocol = "vless" | .argo.trojan_password = ""' >/dev/null
        argo_apply_fixed_tunnel_from_state() { return 1; }
        config_print_nodes() { return 0; }
        prompt() { printf -v "$2" '%s' '2'; }
        module_argo_update_protocol >/dev/null 2>&1 && echo "proto_unexpected_ok"
        printf 'proto=%s\n' "$(st_get '.argo.protocol')"
        st_set '.argo.protocol = "ws"' >/dev/null
        module_argo_update_auth_protocol >/dev/null 2>&1 && echo "auth_unexpected_ok"
        printf 'auth=%s pw_empty=%s\n' \
            "$(st_get '.argo.auth_protocol')" \
            "$( [ -z "$(st_get '.argo.trojan_password')" ] && printf yes || printf no )"
    """)
    assert_true("proto_unexpected_ok" not in out, f"transport update must fail when tunnel apply fails: {out}")
    assert_true("proto=ws" in out, f"module_argo_update_protocol must roll back .argo.protocol on apply failure: {out}")
    assert_true("auth_unexpected_ok" not in out, f"auth update must fail when tunnel apply fails: {out}")
    assert_true("auth=vless" in out, f"module_argo_update_auth_protocol must roll back .argo.auth_protocol on apply failure: {out}")
    assert_true("pw_empty=yes" in out, f"auth rollback must also revert the seeded Trojan password: {out}")


def test_argo_disable_and_uninstall_reset_authentication_state():
    for fn in ["module_argo_uninstall", "install_plan_argo_toggle"]:
        owner = "module_argo_uninstall_inner" if fn == "module_argo_uninstall" else fn
        m = re.search(rf"{owner}\(\) \{{(?P<body>.*?)\n\}}", TEXT, re.S)
        assert_true(m, f"{owner} function missing")
        body = m.group("body")
        assert_true('.argo.auth_protocol = "vless"' in body, f"{owner} must reset Argo auth protocol")
        assert_true('.argo.protocol = "ws"' in body, f"{owner} must reset Argo transport protocol")


def test_trojan_password_generator_is_random_and_validator_safe():
    cp = run_bash_result("""
        source ./xray_2go.sh
        a=$(crypto_gen_trojan_password) || exit 90
        b=$(crypto_gen_trojan_password) || exit 91
        val_trojan_password "${a}" >/dev/null 2>&1 || exit 92
        val_trojan_password "${b}" >/dev/null 2>&1 || exit 93
        [ "${a}" != "${b}" ] || exit 94
    """)
    assert_true(
        cp.returncode == 0,
        f"crypto_gen_trojan_password must emit distinct validator-safe passwords (rc={cp.returncode}): {cp.stdout}",
    )


def test_state_drops_uri_unsafe_trojan_password_and_keeps_valid_one():
    bad = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE='{"uuid":"56b6d850-1e42-48ef-8229-94f5d8292e54","argo":{"enabled":true,"protocol":"ws","auth_protocol":"trojan","trojan_password":"bad#pass?x@y"}}'
        _st_normalize_schema >/dev/null 2>&1
        printf '%s' "${_G_STATE}" | jq -e '.argo.trojan_password == ""' >/dev/null
    """)
    assert_true(
        bad.returncode == 0,
        f"normalization must drop a URI-unsafe stored Trojan password (rc={bad.returncode}): {bad.stdout}",
    )
    good = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE='{"uuid":"56b6d850-1e42-48ef-8229-94f5d8292e54","argo":{"enabled":true,"protocol":"ws","auth_protocol":"trojan","trojan_password":"Good.pass_x~y-z"}}'
        _st_normalize_schema >/dev/null 2>&1
        printf '%s' "${_G_STATE}" | jq -e '.argo.trojan_password == "Good.pass_x~y-z"' >/dev/null
    """)
    assert_true(
        good.returncode == 0,
        f"normalization must keep a validator-safe stored Trojan password (rc={good.returncode}): {good.stdout}",
    )


TROJAN_STATE_SEED = (
    "_G_STATE='{\"uuid\":\"56b6d850-1e42-48ef-8229-94f5d8292e54\","
    "\"argo\":{\"enabled\":true,\"protocol\":\"ws\",\"auth_protocol\":\"trojan\",\"trojan_password\":\"\"}}'"
)


def test_install_plan_trojan_password_entry_generates_and_persists_password():
    out = run_bash("""
        source ./xray_2go.sh
        %s
        _st_normalize_schema >/dev/null 2>&1
        prompt_secret() { printf -v "$2" '%%s' ''; }
        install_plan_argo_update_trojan_password >/dev/null 2>&1 || { echo "rc=fail"; exit 0; }
        _pw=$(st_get '.argo.trojan_password')
        printf 'len=%%s uuid_match=%%s valid=%%s\n' \
            "${#_pw}" \
            "$( [ "${_pw}" = "$(st_get '.uuid')" ] && printf yes || printf no )" \
            "$( val_trojan_password "${_pw}" >/dev/null 2>&1 && printf yes || printf no )"
    """ % TROJAN_STATE_SEED)
    assert_true("rc=fail" not in out, f"empty input must auto-generate a Trojan password: {out}")
    assert_true("valid=yes" in out, f"generated Trojan password must pass the validator: {out}")
    assert_true("uuid_match=no" in out, f"generated Trojan password must be independent from the UUID: {out}")


def test_install_plan_trojan_password_entry_requires_trojan_auth():
    cp = run_bash_result("""
        source ./xray_2go.sh
        declare -F install_plan_argo_update_trojan_password >/dev/null || exit 79
        _G_STATE="${_STATE_DEFAULT}"
        _st_normalize_schema >/dev/null 2>&1
        prompt_secret() { printf -v "$2" '%s' 'ValidPass_123'; }
        install_plan_argo_update_trojan_password >/dev/null 2>&1 && exit 80
        [ "$(st_get '.argo.trojan_password')" = "" ] || exit 81
    """)
    assert_true(
        cp.returncode == 0,
        f"Trojan password entry must refuse while Argo auth is VLESS (rc={cp.returncode}): {cp.stdout}",
    )


def test_install_plan_trojan_password_entry_rejects_uri_unsafe_input():
    cp = run_bash_result("""
        source ./xray_2go.sh
        declare -F install_plan_argo_update_trojan_password >/dev/null || exit 79
        %s
        _st_normalize_schema >/dev/null 2>&1
        st_set '.argo.trojan_password = $p' --arg p 'KeepMe_12345' >/dev/null
        prompt_secret() { printf -v "$2" '%%s' 'bad#pass?x@y'; }
        install_plan_argo_update_trojan_password >/dev/null 2>&1 && exit 80
        [ "$(st_get '.argo.trojan_password')" = "KeepMe_12345" ] || exit 81
    """ % TROJAN_STATE_SEED)
    assert_true(
        cp.returncode == 0,
        f"URI-unsafe input must be rejected without clobbering the stored password (rc={cp.returncode}): {cp.stdout}",
    )


def test_install_plan_trojan_password_entry_accepts_explicit_value():
    cp = run_bash_result("""
        source ./xray_2go.sh
        %s
        _st_normalize_schema >/dev/null 2>&1
        prompt_secret() { printf -v "$2" '%%s' 'Explicit.pass_9~x-y'; }
        install_plan_argo_update_trojan_password >/dev/null 2>&1 || exit 80
        [ "$(st_get '.argo.trojan_password')" = "Explicit.pass_9~x-y" ] || exit 81
    """ % TROJAN_STATE_SEED)
    assert_true(
        cp.returncode == 0,
        f"explicit validator-safe password must be persisted (rc={cp.returncode}): {cp.stdout}",
    )


def test_switching_argo_auth_to_trojan_seeds_independent_password():
    out = run_bash("""
        source ./xray_2go.sh
        _G_STATE="${_STATE_DEFAULT}"
        _st_normalize_schema >/dev/null 2>&1
        st_set '.argo.enabled = true | .argo.protocol = "ws"' >/dev/null
        prompt() { printf -v "$2" '%s' '2'; }
        install_plan_argo_update_auth_protocol >/dev/null 2>&1 || { echo "rc=fail"; exit 0; }
        _pw=$(st_get '.argo.trojan_password')
        printf 'auth=%s empty=%s uuid_match=%s valid=%s\n' \
            "$(st_get '.argo.auth_protocol')" \
            "$( [ -z "${_pw}" ] && printf yes || printf no )" \
            "$( [ "${_pw}" = "$(st_get '.uuid')" ] && printf yes || printf no )" \
            "$( val_trojan_password "${_pw}" >/dev/null 2>&1 && printf yes || printf no )"
    """)
    assert_true("rc=fail" not in out, f"switching Argo auth to Trojan must succeed: {out}")
    assert_true("auth=trojan" in out, f"Argo auth must become Trojan: {out}")
    assert_true("empty=no" in out and "valid=yes" in out, f"switching to Trojan must seed a stored password: {out}")
    assert_true("uuid_match=no" in out, f"seeded Trojan password must not reuse the UUID: {out}")


def test_trojan_password_entry_is_wired_into_menu_and_uses_secret_prompt():
    m = re.search(r"install_plan_argo_update_trojan_password\(\) \{(?P<body>.*?)\n\}", TEXT, re.S)
    assert_true(m, "install_plan_argo_update_trojan_password function missing")
    body = m.group("body")
    assert_true("prompt_secret" in body, "Trojan password entry must read the secret without echoing it")
    assert_true('prompt "Trojan' not in TEXT, "Trojan password must never be read with the echoing prompt helper")
    assert_true("crypto_gen_trojan_password" in body, "Trojan password entry must support auto-generation")
    assert_true("val_trojan_password" in body, "Trojan password entry must validate before writing state")
    menu = re.search(r"unified_menu_argo\(\) \{(?P<body>.*?)\n\}", TEXT, re.S)
    assert_true(menu, "unified_menu_argo function missing")
    menu_body = menu.group("body")
    assert_true("Trojan 密码" in menu_body, "Argo workbench must expose a Trojan password action")
    assert_true(
        "install_plan_argo_update_trojan_password" in menu_body,
        "Argo workbench must route the Trojan password action to the install-plan entry",
    )
    assert_true(
        "update_trojan_password" in menu_body,
        "Argo workbench must route the Trojan password action to the runtime module action",
    )


def test_runtime_trojan_password_update_is_dispatchable_and_persists():
    out = run_bash("""
        source ./xray_2go.sh
        st_init >/dev/null 2>&1
        st_set '.argo.enabled = true | .argo.protocol = "ws" | .argo.auth_protocol = "trojan" | .argo.trojan_password = ""' >/dev/null
        argo_apply_fixed_tunnel_from_state() { return 0; }
        config_print_nodes() { return 0; }
        prompt_secret() { printf -v "$2" '%s' 'Runtime.pass_1~x-y'; }
        module_dispatch argo update_trojan_password >/dev/null 2>&1 || { echo "rc=fail"; exit 0; }
        printf 'pw=%s\n' "$(st_get '.argo.trojan_password')"
    """)
    assert_true("rc=fail" not in out, f"runtime dispatch must support argo:update_trojan_password: {out}")
    assert_true("pw=Runtime.pass_1~x-y" in out, f"runtime Trojan password update must persist the new value: {out}")


def test_runtime_trojan_password_update_rolls_back_on_apply_failure():
    out = run_bash("""
        source ./xray_2go.sh
        declare -F module_argo_update_trojan_password >/dev/null || { echo "rc=missing"; exit 0; }
        st_init >/dev/null 2>&1
        st_set '.argo.enabled = true | .argo.protocol = "ws" | .argo.auth_protocol = "trojan" | .argo.trojan_password = $p' --arg p 'Original.pass_1' >/dev/null
        argo_apply_fixed_tunnel_from_state() { return 1; }
        config_print_nodes() { return 0; }
        prompt_secret() { printf -v "$2" '%s' 'Replacement.pass_2'; }
        module_dispatch argo update_trojan_password >/dev/null 2>&1 && echo "rc=unexpected-ok"
        printf 'pw=%s\n' "$(st_get '.argo.trojan_password')"
    """)
    assert_true("rc=missing" not in out, f"module_argo_update_trojan_password must exist: {out}")
    assert_true("rc=unexpected-ok" not in out, f"runtime Trojan password update must fail when tunnel apply fails: {out}")
    assert_true(
        "pw=Original.pass_1" in out,
        f"runtime Trojan password update must roll back in-memory state on apply failure: {out}",
    )


def test_runtime_trojan_password_update_requires_enabled_argo():
    cp = run_bash_result("""
        source ./xray_2go.sh
        declare -F module_argo_update_trojan_password >/dev/null || exit 79
        st_init >/dev/null 2>&1
        st_set '.argo.enabled = false | .argo.auth_protocol = "trojan"' >/dev/null
        prompt_secret() { printf -v "$2" '%s' 'Should.not_apply1'; }
        module_argo_update_trojan_password >/dev/null 2>&1 && exit 80
        [ "$(st_get '.argo.trojan_password')" = "" ] || exit 81
    """)
    assert_true(
        cp.returncode == 0,
        f"runtime Trojan password update must refuse while Argo is disabled (rc={cp.returncode}): {cp.stdout}",
    )


def test_stored_trojan_password_is_used_by_inbound_and_share_link():
    out = run_bash("""
        source ./xray_2go.sh
        st_init >/dev/null 2>&1
        st_set '.argo.enabled = true | .argo.protocol = "ws" | .argo.auth_protocol = "trojan" | .argo.domain = "t.example.com" | .argo.trojan_password = $p' --arg p 'Link.pass_9~x-y' >/dev/null
        plugin_install_builtins >/dev/null 2>&1
        plugin_load_all >/dev/null 2>&1
        _plg_argo_inbound | jq -r '.settings.clients[0].password' | sed 's/^/inbound=/'
        printf 'link=%s\n' "$(_plg_argo_link)"
    """)
    assert_true("inbound=Link.pass_9~x-y" in out, f"stored Trojan password must drive the inbound: {out}")
    assert_true("link=trojan://Link.pass_9~x-y@" in out, f"stored Trojan password must drive the share link: {out}")


def test_runtime_restart_status_actions_have_single_canonical_owner():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh

declare -F module_restart_action >/dev/null || { echo 'missing_restart_owner'; exit 79; }
declare -F module_status_action >/dev/null || { echo 'missing_status_owner'; exit 80; }

module_restart_action() { printf 'restart=%s\\n' "$1"; }
module_status_action() { printf 'status=%s\\n' "$1"; }

module_dispatch ff restart
module_dispatch argo restart
check_xray
check_argo
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"restart/status canonical-owner RED/GREEN probe failed: {cp.stdout}")
    assert_true("restart=xray" in cp.stdout, f"non-Argo restart must route to the canonical xray owner: {cp.stdout}")
    assert_true("restart=argo" in cp.stdout, f"Argo restart must route to the canonical Argo owner: {cp.stdout}")
    assert_true("status=xray" in cp.stdout, f"xray status must route to the canonical status owner: {cp.stdout}")
    assert_true("status=argo" in cp.stdout, f"Argo status must route to the canonical status owner: {cp.stdout}")

    for function_name, target in (
        ("module_xray_restart", "xray"),
        ("module_argo_restart", "argo"),
        ("check_xray", "xray"),
        ("check_argo", "argo"),
    ):
        match = re.search(
            rf"^{re.escape(function_name)}\(\) \{{(?P<body>.*?)^\}}",
            TEXT,
            re.MULTILINE | re.DOTALL,
        )
        if match is None:
            raise AssertionError(f"compatibility wrapper missing: {function_name}")
        body = match.group("body")
        owner = "module_restart_action" if function_name.startswith("module_") else "module_status_action"
        assert_true(
            f"{owner} {target}" in body,
            f"{function_name} must delegate to {owner} {target}, not duplicate action logic",
        )


def test_runtime_restart_status_canonical_owner_preserves_failure_and_status_contract():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}"
st_init >/dev/null 2>&1

check_xray_install() { return 0; }
svc_restart_xray() { return 1; }
module_restart_action xray >/dev/null 2>&1
printf 'xray_restart_rc=%s\\n' "$?"

svc_exec_mut() { return 0; }
svc_verify_health() { return 1; }
module_restart_action argo >/dev/null 2>&1
printf 'argo_restart_rc=%s\\n' "$?"

svc_exec() { return 0; }
_xray_status=$(module_status_action xray); _xray_status_rc=$?
printf 'xray_status=%s xray_status_rc=%s\\n' "${_xray_status}" "${_xray_status_rc}"

st_set '.argo.enabled = true' >/dev/null
mkdir -p "$(dirname "${ARGO_BIN}")"
touch "${ARGO_BIN}"
_argo_status=$(module_status_action argo); _argo_status_rc=$?
printf 'argo_status=%s argo_status_rc=%s\\n' "${_argo_status}" "${_argo_status_rc}"

svc_exec() { return 1; }
_stopped=$(module_status_action xray); _stopped_rc=$?
printf 'stopped_status=%s stopped_status_rc=%s\\n' "${_stopped}" "${_stopped_rc}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"canonical restart/status behavior probe failed: {cp.stdout}")
    assert_true("xray_restart_rc=1" in cp.stdout, f"xray restart failure must propagate: {cp.stdout}")
    assert_true("argo_restart_rc=1" in cp.stdout, f"Argo health failure must propagate: {cp.stdout}")
    assert_true("xray_status=running xray_status_rc=0" in cp.stdout, f"xray running status contract changed: {cp.stdout}")
    assert_true("argo_status=running argo_status_rc=0" in cp.stdout, f"Argo running status contract changed: {cp.stdout}")
    assert_true("stopped_status=stopped stopped_status_rc=1" in cp.stdout, f"stopped status contract changed: {cp.stdout}")


def test_runtime_socks_disable_failure_restores_previous_state():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}"
st_init >/dev/null 2>&1
st_set '.socks.enabled = true' >/dev/null
st_persist >/dev/null 2>&1

_module_disable_commit() { return 1; }
module_socks_action disable >/dev/null 2>&1
_rc=$?
_mem=$(st_get '.socks.enabled')
_disk=$(jq -r '.socks.enabled' "${STATE_FILE}")
printf 'rc=%s memory=%s disk=%s\\n' "${_rc}" "${_mem}" "${_disk}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"socks disable rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=true disk=true" in cp.stdout,
        f"failed SOCKS disable must restore committed state: {cp.stdout}",
    )


def test_runtime_socks_enable_failure_restores_previous_state():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}"
st_init >/dev/null 2>&1
st_set '.socks.enabled = true' >/dev/null
st_persist >/dev/null 2>&1

_module_enable_commit() { return 1; }
module_socks_action enable >/dev/null 2>&1
_rc=$?
_mem=$(st_get '.socks.enabled')
_disk=$(jq -r '.socks.enabled' "${STATE_FILE}")
printf 'rc=%s memory=%s disk=%s\\n' "${_rc}" "${_mem}" "${_disk}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"socks enable rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=true disk=true" in cp.stdout,
        f"failed SOCKS enable must restore committed state: {cp.stdout}",
    )


def test_runtime_vltcp_enable_failure_restores_previous_state():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}"
st_init >/dev/null 2>&1
st_set '.vltcp.enabled = true' >/dev/null
st_persist >/dev/null 2>&1

_module_enable_commit() { return 1; }
module_vltcp_enable >/dev/null 2>&1
_rc=$?
_mem=$(st_get '.vltcp.enabled')
_disk=$(jq -r '.vltcp.enabled' "${STATE_FILE}")
printf 'rc=%s memory=%s disk=%s\\n' "${_rc}" "${_mem}" "${_disk}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"vltcp enable rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=true disk=true" in cp.stdout,
        f"failed VLESS-TCP enable must restore committed state: {cp.stdout}",
    )


def test_shared_enable_helper_restores_state_on_commit_failure():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}"
st_init >/dev/null 2>&1
st_set '.vltcp.enabled = true' >/dev/null
st_persist >/dev/null 2>&1

_module_enable_commit() { return 1; }
_module_enable_with_state '.vltcp.enabled = false' 'VLESS-TCP'
_rc=$?
_mem=$(st_get '.vltcp.enabled')
_disk=$(jq -r '.vltcp.enabled' "${STATE_FILE}")
printf 'rc=%s memory=%s disk=%s\\n' "${_rc}" "${_mem}" "${_disk}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"shared enable rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=true disk=true" in cp.stdout,
        f"shared enable helper must restore prior state: {cp.stdout}",
    )


def test_runtime_ff_enable_failure_restores_complete_previous_state():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}"
st_init >/dev/null 2>&1
st_set '.ff.enabled = true | .ff.protocol = "tcphttp" | .ff.host = "old.example"' >/dev/null
st_persist >/dev/null 2>&1

_module_enable_commit() { return 1; }
module_ff_enable >/dev/null 2>&1
_rc=$?
printf 'rc=%s memory=%s/%s/%s disk=%s/%s/%s\\n' \\
    "${_rc}" \\
    "$(st_get '.ff.enabled')" \\
    "$(st_get '.ff.protocol')" \\
    "$(st_get '.ff.host')" \\
    "$(jq -r '.ff.enabled' "${STATE_FILE}")" \\
    "$(jq -r '.ff.protocol' "${STATE_FILE}")" \\
    "$(jq -r '.ff.host' "${STATE_FILE}")"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"FreeFlow enable rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=true/tcphttp/old.example disk=true/tcphttp/old.example" in cp.stdout,
        f"failed FreeFlow enable must restore complete prior state: {cp.stdout}",
    )


def test_runtime_reality_enable_failure_restores_generated_material():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}" "$(dirname "${XRAY_BIN}")"
printf '%s\\n' \\
    '#!/bin/sh' \\
    'case "${1:-}" in' \\
    '  x25519) printf "%s\\n%s\\n" "Private key: NEWPRIVATEKEY_1234567890" "Public key: NEWPUBLICKEY_1234567890" ;;' \\
    '  *) exit 1 ;;' \\
    'esac' > "${XRAY_BIN}"
chmod 700 "${XRAY_BIN}"
st_init >/dev/null 2>&1
st_set '.reality.enabled = false | .reality.pvk = null | .reality.pbk = null | .reality.sid = "oldsid"' >/dev/null
st_persist >/dev/null 2>&1

_module_enable_commit() { return 1; }
module_reality_enable >/dev/null 2>&1
_rc=$?
printf 'rc=%s memory=%s/%s/%s/%s disk=%s/%s/%s/%s\\n' \\
    "${_rc}" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.reality.enabled')" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.reality.pvk')" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.reality.pbk')" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.reality.sid')" \\
    "$(jq -r '.reality.enabled' "${STATE_FILE}")" \\
    "$(jq -r '.reality.pvk' "${STATE_FILE}")" \\
    "$(jq -r '.reality.pbk' "${STATE_FILE}")" \\
    "$(jq -r '.reality.sid' "${STATE_FILE}")"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"Reality enable rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=false/null/null/oldsid disk=false/null/null/oldsid" in cp.stdout,
        f"failed Reality enable must restore generated material and prior state: {cp.stdout}",
    )


def test_runtime_transaction_restores_cross_artifact_state_after_commit_failure():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}" "${_SVC_SYSTEMD_DIR}"
st_init >/dev/null 2>&1
st_set '.socks.enabled = false' >/dev/null
st_persist >/dev/null 2>&1
printf 'old-config' > "${CONFIG_FILE}"
printf 'old-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service"
printf 'old-env' > "${_ARGO_ENV_FILE}"
printf 'old-tunnel' > "${WORK_DIR}/tunnel.yml"
printf 'nft:1080/tcp\\n' > "${_FW_RULES_FILE}"
printf '1080\\n' > "${_FW_PORTS_FILE}"

svc_exec() { return 1; }
svc_exec_mut() { return 0; }
_fw_restore_managed_snapshot() { return 0; }
_module_enable_commit() {
    printf 'new-config' > "${CONFIG_FILE}"
    printf '{"socks":{"enabled":true}}' > "${STATE_FILE}"
    printf 'new-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service"
    printf 'new-env' > "${_ARGO_ENV_FILE}"
    printf 'new-tunnel' > "${WORK_DIR}/tunnel.yml"
    printf 'iptables:9999/tcp\\n' > "${_FW_RULES_FILE}"
    printf '9999\\n' > "${_FW_PORTS_FILE}"
    return 1
}
module_socks_enable >/dev/null 2>&1
_rc=$?
printf 'rc=%s memory=%s config=%s state=%s service=%s env=%s tunnel=%s fw=%s ports=%s\\n' \\
    "${_rc}" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.socks.enabled')" \\
    "$(cat "${CONFIG_FILE}")" \\
    "$(jq -c . "${STATE_FILE}")" \\
    "$(cat "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service")" \\
    "$(cat "${_ARGO_ENV_FILE}")" \\
    "$(cat "${WORK_DIR}/tunnel.yml")" \\
    "$(cat "${_FW_RULES_FILE}")" \\
    "$(cat "${_FW_PORTS_FILE}")"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"transaction rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=false config=old-config state={" in cp.stdout
        and '"enabled":false' in cp.stdout
        and "service=old-service env=old-env tunnel=old-tunnel fw=nft:1080/tcp ports=1080" in cp.stdout,
        f"failed commit must restore all artifacts and state: {cp.stdout}",
    )


def test_runtime_disable_transaction_restores_cross_artifact_state_after_commit_failure():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}" "${_SVC_SYSTEMD_DIR}"
st_init >/dev/null 2>&1
st_set '.socks.enabled = true' >/dev/null
st_persist >/dev/null 2>&1
printf 'old-config' > "${CONFIG_FILE}"
printf 'old-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service"
printf 'old-env' > "${_ARGO_ENV_FILE}"
printf 'old-tunnel' > "${WORK_DIR}/tunnel.yml"
printf 'nft:1080/tcp\\n' > "${_FW_RULES_FILE}"
printf '1080\\n' > "${_FW_PORTS_FILE}"
_SERVICE_ACTIVE=1
_SERVICE_ENABLED=1
svc_exec() {
    case "$1" in
        status) [ "${_SERVICE_ACTIVE}" = 1 ] ;;
        *) return 1 ;;
    esac
}
svc_is_enabled() { [ "${_SERVICE_ENABLED}" = 1 ]; }
svc_exec_mut() {
    case "$1" in
        start) _SERVICE_ACTIVE=1 ;;
        stop) _SERVICE_ACTIVE=0 ;;
        enable) _SERVICE_ENABLED=1 ;;
        disable) _SERVICE_ENABLED=0 ;;
        *) return 1 ;;
    esac
}
_fw_restore_managed_snapshot() { return 0; }
_module_disable_commit() {
    printf 'new-config' > "${CONFIG_FILE}"
    printf '{"socks":{"enabled":false}}' > "${STATE_FILE}"
    printf 'new-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service"
    printf 'new-env' > "${_ARGO_ENV_FILE}"
    printf 'new-tunnel' > "${WORK_DIR}/tunnel.yml"
    printf 'iptables:9999/tcp\\n' > "${_FW_RULES_FILE}"
    printf '9999\\n' > "${_FW_PORTS_FILE}"
    _SERVICE_ACTIVE=0
    _SERVICE_ENABLED=0
    return 1
}
module_socks_action disable >/dev/null 2>&1
_rc=$?
printf 'rc=%s memory=%s config=%s state=%s service=%s env=%s tunnel=%s fw=%s ports=%s active=%s enabled=%s\\n' \\
    "${_rc}" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.socks.enabled')" \\
    "$(cat "${CONFIG_FILE}")" \\
    "$(jq -c . "${STATE_FILE}")" \\
    "$(cat "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service")" \\
    "$(cat "${_ARGO_ENV_FILE}")" \\
    "$(cat "${WORK_DIR}/tunnel.yml")" \\
    "$(cat "${_FW_RULES_FILE}")" \\
    "$(cat "${_FW_PORTS_FILE}")" \\
    "${_SERVICE_ACTIVE}" "${_SERVICE_ENABLED}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"disable transaction rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=true config=old-config state={" in cp.stdout
        and '"enabled":true' in cp.stdout
        and "service=old-service env=old-env tunnel=old-tunnel fw=nft:1080/tcp ports=1080 active=1 enabled=1" in cp.stdout,
        f"failed disable commit must restore all artifacts and state: {cp.stdout}",
    )


def test_runtime_commit_restores_cross_artifact_state_after_failure():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}" "${_SVC_SYSTEMD_DIR}"
st_init >/dev/null 2>&1
st_set '.socks.enabled = true' >/dev/null
st_persist >/dev/null 2>&1
printf 'old-config' > "${CONFIG_FILE}"
printf 'old-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service"
printf 'old-env' > "${_ARGO_ENV_FILE}"
printf 'old-tunnel' > "${WORK_DIR}/tunnel.yml"
printf 'nft:1080/tcp\\n' > "${_FW_RULES_FILE}"
printf '1080\\n' > "${_FW_PORTS_FILE}"
_commit_inner() {
    st_set '.socks.enabled = false' >/dev/null
    st_persist >/dev/null 2>&1
    printf 'new-config' > "${CONFIG_FILE}"
    printf 'new-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service"
    printf 'new-env' > "${_ARGO_ENV_FILE}"
    printf 'new-tunnel' > "${WORK_DIR}/tunnel.yml"
    printf 'iptables:9999/tcp\\n' > "${_FW_RULES_FILE}"
    printf '9999\\n' > "${_FW_PORTS_FILE}"
    return 1
}
_commit >/dev/null 2>&1
_rc=$?
printf 'rc=%s memory=%s config=%s state=%s service=%s env=%s tunnel=%s fw=%s ports=%s\\n' \\
    "${_rc}" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.socks.enabled')" \\
    "$(cat "${CONFIG_FILE}")" \\
    "$(jq -c . "${STATE_FILE}")" \\
    "$(cat "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service")" \\
    "$(cat "${_ARGO_ENV_FILE}")" \\
    "$(cat "${WORK_DIR}/tunnel.yml")" \\
    "$(cat "${_FW_RULES_FILE}")" \\
    "$(cat "${_FW_PORTS_FILE}")"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"ordinary commit rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=true config=old-config state={" in cp.stdout
        and '"enabled":true' in cp.stdout
        and "service=old-service env=old-env tunnel=old-tunnel fw=nft:1080/tcp ports=1080" in cp.stdout,
        f"failed ordinary commit must restore all artifacts and state: {cp.stdout}",
    )


def test_runtime_transaction_restores_service_enabled_state_after_commit_failure():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}"
st_init >/dev/null 2>&1
st_set '.socks.enabled = false' >/dev/null
st_persist >/dev/null 2>&1
_SERVICE_ACTIVE=1
_SERVICE_ENABLED=1
svc_exec() {
    case "$1" in
        status) [ "${_SERVICE_ACTIVE}" = 1 ] ;;
        *) return 1 ;;
    esac
}
svc_is_enabled() { [ "${_SERVICE_ENABLED}" = 1 ]; }
svc_exec_mut() {
    case "$1" in
        start) _SERVICE_ACTIVE=1 ;;
        stop) _SERVICE_ACTIVE=0 ;;
        enable) _SERVICE_ENABLED=1 ;;
        disable) _SERVICE_ENABLED=0 ;;
        *) return 1 ;;
    esac
}
_fw_restore_managed_snapshot() { return 0; }
_module_enable_commit() {
    _SERVICE_ACTIVE=0
    _SERVICE_ENABLED=0
    return 1
}
module_socks_enable >/dev/null 2>&1
_rc=$?
printf 'rc=%s active=%s enabled=%s\\n' "${_rc}" "${_SERVICE_ACTIVE}" "${_SERVICE_ENABLED}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"service rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 active=1 enabled=1" in cp.stdout,
        f"failed commit must restore service active and enabled state: {cp.stdout}",
    )


def test_runtime_vlquic_enable_restores_cross_artifact_state_after_config_failure():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}" "${_SVC_SYSTEMD_DIR}"
printf 'cert' > "${WORK_DIR}/cert.pem"
printf 'key' > "${WORK_DIR}/key.pem"
st_init >/dev/null 2>&1
st_set '.vlquic.enabled = false | .vlquic.domain = "old.example" | .vlquic.cert = "'"${WORK_DIR}"'/cert.pem" | .vlquic.key = "'"${WORK_DIR}"'/key.pem"' >/dev/null
st_persist >/dev/null 2>&1
printf 'old-config' > "${CONFIG_FILE}"
printf 'old-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service"
printf 'old-env' > "${_ARGO_ENV_FILE}"
printf 'old-tunnel' > "${WORK_DIR}/tunnel.yml"
printf 'nft:1080/tcp\\n' > "${_FW_RULES_FILE}"
printf '1080\\n' > "${_FW_PORTS_FILE}"
fw_reconcile() { return 0; }
config_apply() {
    printf 'new-config' > "${CONFIG_FILE}"
    printf 'new-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service"
    printf 'new-env' > "${_ARGO_ENV_FILE}"
    printf 'new-tunnel' > "${WORK_DIR}/tunnel.yml"
    printf 'iptables:9999/tcp\\n' > "${_FW_RULES_FILE}"
    printf '9999\\n' > "${_FW_PORTS_FILE}"
    return 1
}
module_vlquic_enable >/dev/null 2>&1
_rc=$?
printf 'rc=%s memory=%s config=%s state=%s service=%s env=%s tunnel=%s fw=%s ports=%s\\n' \\
    "${_rc}" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.vlquic.enabled')" \\
    "$(cat "${CONFIG_FILE}")" \\
    "$(jq -c . "${STATE_FILE}")" \\
    "$(cat "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service")" \\
    "$(cat "${_ARGO_ENV_FILE}")" \\
    "$(cat "${WORK_DIR}/tunnel.yml")" \\
    "$(cat "${_FW_RULES_FILE}")" \\
    "$(cat "${_FW_PORTS_FILE}")"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"VLESS-XHTTP-H3 enable rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=false config=old-config state={" in cp.stdout
        and '"enabled":false' in cp.stdout
        and "service=old-service env=old-env tunnel=old-tunnel fw=nft:1080/tcp ports=1080" in cp.stdout,
        f"failed VLESS-XHTTP-H3 enable must restore all artifacts and state: {cp.stdout}",
    )


def test_runtime_cforigin_enable_failure_restores_precommit_defaults():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}"
st_init >/dev/null 2>&1
st_set '.cforigin.enabled = false | .cforigin.protocol = null | .cforigin.path = null | .cforigin.listen = null | .cforigin.edge_port = null | .cforigin.domain = "old.example"' >/dev/null
st_persist >/dev/null 2>&1

_module_enable_commit() { return 1; }
module_cforigin_enable >/dev/null 2>&1
_rc=$?
printf 'rc=%s memory=%s/%s/%s/%s/%s/%s disk=%s/%s/%s/%s/%s/%s\\n' \\
    "${_rc}" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.cforigin.enabled')" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.cforigin.protocol')" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.cforigin.path')" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.cforigin.listen')" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.cforigin.edge_port')" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.cforigin.domain')" \\
    "$(jq -r '.cforigin.enabled' "${STATE_FILE}")" \\
    "$(jq -r '.cforigin.protocol' "${STATE_FILE}")" \\
    "$(jq -r '.cforigin.path' "${STATE_FILE}")" \\
    "$(jq -r '.cforigin.listen' "${STATE_FILE}")" \\
    "$(jq -r '.cforigin.edge_port' "${STATE_FILE}")" \\
    "$(jq -r '.cforigin.domain' "${STATE_FILE}")"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"CF Origin enable rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=false/null/null/null/null/old.example disk=false/null/null/null/null/old.example" in cp.stdout,
        f"failed CF Origin enable must restore pre-commit defaults and prior state: {cp.stdout}",
    )


def test_readme_documents_trojan_argo_capability():
    assert_true("Trojan" in README_TEXT, "README must document the Trojan Argo capability")
    assert_true(
        "Trojan + WS" in README_TEXT,
        "README must state that Trojan Argo is limited to WS transport",
    )
    assert_true(
        "8-128" in README_TEXT and "URL-safe" in README_TEXT,
        "README must document the Trojan password charset/length contract",
    )
    assert_true(
        "UUID" in README_TEXT and "回退" in README_TEXT,
        "README must document the UUID fallback when no Trojan password is stored",
    )


def main():
    from probe_matrix import run_probe_matrix

    report = run_probe_matrix(Path(__file__))
    if report["failed"]:
        for failure in report["failed"]:
            print(f"FAIL {failure['name']} [{failure['category']}]\\n{failure['output']}")
        raise SystemExit(1)
    for result in report["results"]:
        print(f"PASS {result['name']}")


if __name__ == "__main__":
    main()
