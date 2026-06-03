#!/usr/bin/env python3
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "xray_2go.sh"
TEXT = SCRIPT.read_text(encoding="utf-8")


def assert_true(cond, msg):
    if not cond:
        raise AssertionError(msg)


def run_bash(script: str) -> str:
    cp = subprocess.run(
        ["bash", "-lc", script],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=20,
        check=True,
    )
    return cp.stdout


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
    assert_true('printf \'%s\\n\' "${_used_wild_ports}" | grep -qxF "${_p}"' in TEXT, "specific listen must conflict with existing wildcard same-port listener")
    assert_true('printf \'%s\\n\' "${_used_exact_keys}" | grep -qE ":${_p}$"' in TEXT, "wildcard listen must conflict with existing specific same-port listener")
    assert_true("^vless://" in TEXT and "grep -E" in TEXT, "node output should filter plugin link noise and only print vless links")


def test_plugin_loader_validates_before_source_and_loads_in_subshell():
    body = TEXT[TEXT.index('plugin_load_all()'):TEXT.index('plugin_install_builtins()')]
    assert_true('val_plugin_name "${_name}"' in body, "plugin loader must validate plugin filename before source")
    assert_true('_plugin_contract_ok' in body, "plugin loader must inspect plugin contract before source")
    assert_true('bash -n "${_f}"' in TEXT, "plugin loader must syntax-check plugin before source")
    assert_true('(\n        # 先在子 shell' in TEXT and 'source "${_f}" >/dev/null 2>&1 || exit 1' in TEXT, "plugin contract check should source in a subshell first")
    assert_true('插件文件名不合法' in TEXT and '接口不完整，已跳过且未加载' in TEXT, "plugin loader should report rejected plugins clearly")


def test_argo_env_final_token_validation_and_menu_install_state():
    env_body = TEXT[TEXT.index('_svc_write_argo_env()'):TEXT.index('svc_apply_xray()')]
    assert_true('val_argo_token' in env_body, "Argo env writer must revalidate final token before writing env")
    assert_true('Argo token 格式异常，拒绝写入 env' in TEXT, "Argo env writer should fail closed on invalid persisted token")
    assert_true('check_xray_install()' in TEXT and '_MENU_XI' in TEXT, "menu should track installed state separately from running state")
    assert_true('Xray-2go 已安装但未运行' in TEXT, "install menu should not treat stopped service as uninstalled")
    assert_true('自动修正' not in TEXT and '不会自动更换' in TEXT, "port conflict prompts must match current fail/manual behavior")


def test_install_service_and_firewall_fail_closed_status():
    install_body = TEXT[TEXT.index('exec_install()'):TEXT.index('exec_uninstall()')]
    helper_body = TEXT[TEXT.index('svc_enable_start_verify()'):TEXT.index('# ==============================================================================', TEXT.index('svc_enable_start_verify()'))]
    assert_true('fw_reconcile || { _install_rollback' in install_body, "install must rollback/fail when firewall reconcile fails")
    assert_true('svc_enable_start_verify "${_SVC_XRAY}" 8 required' in install_body, "xray install start path should use shared verified start helper")
    assert_true('svc_enable_start_verify "${_SVC_TUNNEL}" 0 optional' in install_body, "tunnel install start path should use shared optional start helper")
    assert_true('svc_exec_mut enable "${_svc}"' in helper_body and 'svc_exec_mut start  "${_svc}"' in helper_body, "service helper must centralize enable/start")
    assert_true('svc_verify_health "${_svc}" "${_max}"' in helper_body, "service helper must verify health when max wait > 0")
    assert_true('log_ok "${_svc} 已启动"' in helper_body, "service helper success message missing")
    assert_true('log_warn "${_svc} 启动失败' in helper_body, "optional service start failure warning missing")


def test_menu_status_and_commit_helpers_are_shared():
    menu_helpers = TEXT[TEXT.index('_menu_input_port_proto()'):TEXT.index('check_xray_install()')]
    assert_true('_xray_runtime_status()' in menu_helpers, "menu should share xray runtime status helper")
    assert_true('_menu_print_module_status()' in menu_helpers, "menu should share module status renderer")
    assert_true('_module_apply_persist_print()' in menu_helpers, "menu should share apply/persist/print commit helper")
    for body_name in ['manage_reality()', 'manage_vltcp()', 'manage_vlquic()', 'manage_cforigin()']:
        body = TEXT[TEXT.index(body_name):TEXT.index('\n}\n', TEXT.index(body_name))]
        assert_true('_xray_runtime_status' in body, f"{body_name} should use shared runtime status helper")
        assert_true('_menu_print_module_status' in body, f"{body_name} should use shared module status renderer")


def test_single_file_module_registry_drives_main_status():
    assert_true('_MODULE_IDS="argo ff reality vltcp vlquic cforigin"' in TEXT, "single-file module registry must list all modules")
    assert_true('module_summary()' in TEXT and 'module_label()' in TEXT, "module metadata helpers missing")
    collect_body = TEXT[TEXT.index('_menu_collect_status()'):TEXT.index('_menu_render()')]
    for mod in ['argo', 'ff', 'reality', 'vltcp', 'vlquic', 'cforigin']:
        assert_true(f'module_summary {mod}' in collect_body, f"main status should be driven by module_summary for {mod}")
    assert_true('module_dispatch()' in TEXT, "module dispatcher skeleton missing")
    menu_body = TEXT[TEXT.index('menu()'):TEXT.index('# ==============================================================================', TEXT.index('menu()'))]
    for key, mod in [('1', 'xray install'), ('2', 'xray uninstall'), ('3', 'argo'), ('4', 'reality'), ('5', 'vltcp'), ('6', 'vlquic'), ('7', 'ff'), ('8', 'cforigin'), ('9', 'nodes show'), ('10', 'config update_uuid'), ('s', 'config update_shortcut')]:
        assert_true(f'{key}) module_dispatch {mod} ;;' in menu_body, f"main menu should route {mod} via module_dispatch")
    for forbidden in ['_menu_do_install', 'exec_uninstall', 'config_print_nodes', 'cforigin_print_cloudflare_hint', 'exec_update_uuid', 'exec_update_shortcut']:
        assert_true(forbidden not in menu_body, f"main menu should be dispatcher-only, found direct action: {forbidden}")


def test_single_file_module_dispatch_actions():
    dispatch_body = TEXT[TEXT.index('module_dispatch()'):TEXT.index('# 交互输入端口', TEXT.index('module_dispatch()'))]
    for token in ['_action="${2:-menu}"', 'xray:install)', 'xray:uninstall)', 'nodes:show)', 'config:update_uuid)', 'config:update_shortcut)', 'argo:restart)', 'reality:show)', 'vltcp:show)', 'vlquic:restart)', 'ff:show)', 'cforigin:show)']:
        assert_true(token in dispatch_body, f"module_dispatch action route missing: {token}")
    for fn in ['module_xray_install()', 'module_xray_uninstall()', 'module_nodes_show()', 'module_config_update_uuid()', 'module_config_update_shortcut()', 'module_xray_restart()', 'module_argo_restart()', 'module_show_nodes()', 'module_cforigin_show()']:
        assert_true(fn in TEXT, f"module action helper missing: {fn}")
    assert_true('_module_action_or_continue reality restart' in TEXT and '_module_action_or_continue vltcp show' in TEXT, "module menus should route representative actions through shared dispatch wrapper")


def test_single_file_module_enable_disable_actions():
    dispatch_body = TEXT[TEXT.index('module_dispatch()'):TEXT.index('# 交互输入端口', TEXT.index('module_dispatch()'))]
    for token in ['ff:enable)', 'ff:disable)', 'reality:enable)', 'vltcp:disable)', 'cforigin:enable)', 'cforigin:disable)']:
        assert_true(token in dispatch_body, f"module_dispatch enable/disable route missing: {token}")
    for fn in ['module_ff_enable()', 'module_ff_disable()', 'module_reality_enable()', 'module_vltcp_enable()', 'module_cforigin_enable()', 'module_cforigin_disable()']:
        assert_true(fn in TEXT, f"module enable/disable helper missing: {fn}")
    for body_name, mod in [('manage_freeflow()', 'ff'), ('manage_reality()', 'reality'), ('manage_vltcp()', 'vltcp'), ('manage_cforigin()', 'cforigin')]:
        body = TEXT[TEXT.index(body_name):TEXT.index('\n}\n', TEXT.index(body_name))]
        assert_true(f'_module_action_or_continue {mod} enable' in body, f"{body_name} enable should route through module_dispatch")
        assert_true(f'_module_action_or_continue {mod} disable' in body, f"{body_name} disable should route through module_dispatch")


def test_single_file_module_uninstall_update_actions():
    dispatch_body = TEXT[TEXT.index('module_dispatch()'):TEXT.index('# 交互输入端口', TEXT.index('module_dispatch()'))]
    for token in ['ff:uninstall)', 'reality:uninstall)', 'vltcp:uninstall)', 'vlquic:update_port)', 'cforigin:uninstall)', 'cforigin:update_port)']:
        assert_true(token in dispatch_body, f"module_dispatch uninstall/update route missing: {token}")
    for fn in ['module_ff_uninstall()', 'module_reality_uninstall()', 'module_vltcp_uninstall()', 'module_vlquic_update_port()', 'module_cforigin_uninstall()', 'module_cforigin_update_port()']:
        assert_true(fn in TEXT, f"module uninstall/update helper missing: {fn}")
    for body_name, mod in [('manage_freeflow()', 'ff'), ('manage_reality()', 'reality'), ('manage_vltcp()', 'vltcp'), ('manage_vlquic()', 'vlquic'), ('manage_cforigin()', 'cforigin')]:
        body = TEXT[TEXT.index(body_name):TEXT.index('\n}\n', TEXT.index(body_name))]
        assert_true(f'_module_action_or_continue {mod} uninstall' in body, f"{body_name} uninstall should route through module_dispatch")
    assert_true('_module_action_or_continue vlquic update_port' in TEXT and '_module_action_or_continue cforigin update_port' in TEXT, "representative port updates should route through module_dispatch")


def test_single_file_module_config_update_actions():
    dispatch_body = TEXT[TEXT.index('module_dispatch()'):TEXT.index('# 交互输入端口', TEXT.index('module_dispatch()'))]
    for token in ['reality:update_transport)', 'vltcp:update_listen)', 'vlquic:update_listen)', 'cforigin:update_protocol)', 'cforigin:update_path)', 'cforigin:update_listen)']:
        assert_true(token in dispatch_body, f"module_dispatch config update route missing: {token}")
    for fn in ['module_reality_update_transport()', 'module_vltcp_update_listen()', 'module_vlquic_update_listen()', 'module_cforigin_update_protocol()', 'module_cforigin_update_path()', 'module_cforigin_update_listen()']:
        assert_true(fn in TEXT, f"module config update helper missing: {fn}")
    for marker in ['_module_action_or_continue reality update_transport', '_module_action_or_continue vltcp update_listen', '_module_action_or_continue vlquic update_listen', '_module_action_or_continue cforigin update_protocol', '_module_action_or_continue cforigin update_path', '_module_action_or_continue cforigin update_listen']:
        assert_true(marker in TEXT, f"menu should route config update through dispatcher: {marker}")


def test_single_file_module_argo_freeflow_actions():
    dispatch_body = TEXT[TEXT.index('module_dispatch()'):TEXT.index('# 交互输入端口', TEXT.index('module_dispatch()'))]
    for token in ['argo:enable)', 'argo:disable)', 'argo:uninstall)', 'argo:update_protocol)', 'argo:update_port)', 'ff:update_mode)', 'ff:update_host_or_path)', 'ff:update_port)']:
        assert_true(token in dispatch_body, f"module_dispatch Argo/FreeFlow route missing: {token}")
    for fn in ['module_argo_enable()', 'module_argo_disable()', 'module_argo_uninstall()', 'module_argo_update_protocol()', 'module_argo_update_port()', 'module_ff_update_mode()', 'module_ff_update_host_or_path()', 'module_ff_update_port()']:
        assert_true(fn in TEXT, f"Argo/FreeFlow action helper missing: {fn}")
    for marker in ['_module_action_or_continue argo enable', '_module_action_or_continue argo disable', '_module_action_or_continue argo uninstall', '_module_action_or_continue argo update_protocol', '_module_action_or_continue argo update_port', '_module_action_or_continue ff update_mode', '_module_action_or_continue ff update_host_or_path', '_module_action_or_continue ff update_port']:
        assert_true(marker in TEXT, f"menu should route Argo/FreeFlow action through dispatcher: {marker}")


def test_single_file_module_final_complex_actions():
    dispatch_body = TEXT[TEXT.index('module_dispatch()'):TEXT.index('# 交互输入端口', TEXT.index('module_dispatch()'))]
    for token in ['reality:update_sni)', 'reality:regenerate_keys)', 'vlquic:enable)', 'vlquic:disable)', 'vlquic:update_cert)', 'cforigin:update_cert)', 'cforigin:update_edge_port)', 'cforigin:toggle_edge_h3)']:
        assert_true(token in dispatch_body, f"module_dispatch final complex route missing: {token}")
    for fn in ['module_reality_update_sni()', 'module_reality_regenerate_keys()', 'module_vlquic_enable()', 'module_vlquic_disable()', 'module_vlquic_update_cert()', 'module_cforigin_update_cert()', 'module_cforigin_update_edge_port()', 'module_cforigin_toggle_edge_h3()']:
        assert_true(fn in TEXT, f"final complex action helper missing: {fn}")
    for marker in ['_module_action_or_continue reality update_sni', '_module_action_or_continue reality regenerate_keys', '_module_action_or_continue vlquic enable', '_module_action_or_continue vlquic disable', '_module_action_or_continue vlquic update_cert', '_module_action_or_continue cforigin update_cert', '_module_action_or_continue cforigin update_edge_port', '_module_action_or_continue cforigin toggle_edge_h3']:
        assert_true(marker in TEXT, f"menu should route final complex action through dispatcher: {marker}")


def test_single_file_manage_shells_are_dispatch_only():
    forbidden = ['st_set ', 'config_apply', 'st_persist', 'fw_reconcile', 'crypto_gen_', 'vlquic_config_cert', 'cforigin_config_cert', 'exec_update_argo_port', 'ask_freeflow_mode']
    for body_name in ['manage_argo()', 'manage_freeflow()', 'manage_reality()', 'manage_vltcp()', 'manage_vlquic()', 'manage_cforigin()']:
        body = TEXT[TEXT.index(body_name):TEXT.index('\n}\n', TEXT.index(body_name))]
        for token in forbidden:
            assert_true(token not in body, f"{body_name} should not contain business operation token: {token}")
        assert_true(body.count('_module_action_or_continue') >= 6, f"{body_name} should be a dispatcher-driven menu shell")
    assert_true('_manage_module_entry_check()' in TEXT and '_module_action_or_continue()' in TEXT, "shared manage shell helpers missing")
    assert_true(TEXT.count('_manage_module_entry_check || return') >= 6, "all manage_* functions should use shared entry guard")
    assert_true(TEXT.count('_module_action_or_continue') >= 20, "menu actions should use shared dispatch wrapper")


def test_single_file_menu_render_helpers():
    assert_true('_menu_print_action()' in TEXT and '_menu_print_back()' in TEXT, "menu render should use shared action/back helpers")
    for body_name in ['manage_argo()', 'manage_freeflow()', 'manage_reality()', 'manage_vltcp()', 'manage_vlquic()', 'manage_cforigin()']:
        body = TEXT[TEXT.index(body_name):TEXT.index('\n}\n', TEXT.index(body_name))]
        assert_true('_menu_print_action' in body, f"{body_name} should use shared action renderer")
        assert_true('_menu_print_back' in body, f"{body_name} should use shared back renderer")


def test_single_file_module_transaction_helpers():
    helper_area = TEXT[TEXT.index('_module_disable_commit()'):TEXT.index('# ==============================================================================', TEXT.index('_module_disable_commit()'))]
    assert_true('_module_enable_commit()' in helper_area and '_module_apply_if_enabled()' in helper_area, "module transaction helpers missing")
    for body_name in ['manage_freeflow()', 'manage_reality()', 'manage_vltcp()', 'manage_cforigin()']:
        body = TEXT[TEXT.index(body_name):TEXT.index('\n}\n', TEXT.index(body_name))]
        assert_true('_module_enable_commit' in body or 'module_dispatch' in body or '_module_action_or_continue' in body, f"{body_name} enable path should use shared transaction helper or dispatcher")
    assert_true('_module_apply_if_enabled "${_en}"' in TEXT, "enabled-only config updates should use shared apply helper")


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
    assert_true('_menu_update_port vlquic udp udp' in TEXT, "VLQUIC management port input must preserve UDP conflict checks")


def test_state_schema_and_plugin_permission_hardening():
    assert_true('.ports = {"argo":18888,"ff":8080,"reality":443,"vltcp":1234,"vlquic":443,"cforigin":28888}' in TEXT, "ports schema initialization must include cforigin")
    assert_true('_plugin_path_safe()' in TEXT and 'stat -c' in TEXT and '_plugin_path_safe "${PLUGIN_DIR}"' in TEXT, "plugin loader must enforce ownership/mode before source")
    assert_true('val_port "${_value}"' in TEXT and 'legacy 端口字段非法' in TEXT, "legacy port migration must validate bad values explicitly")


def main():
    tests = [v for k, v in globals().items() if k.startswith("test_")]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")


if __name__ == "__main__":
    main()
