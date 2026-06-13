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
    assert_true("^(vless|socks)://" in TEXT and "grep -E" in TEXT, "node output should filter plugin link noise and print supported share links")


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
    install_body = TEXT[TEXT.index('module_xray_install_core()'):TEXT.index('module_xray_uninstall()')]
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
    assert_true('_MODULE_IDS="argo ff reality vltcp vlquic cforigin socks"' in TEXT, "single-file module registry must list all modules")
    assert_true('module_summary()' in TEXT and 'module_label()' in TEXT, "module metadata helpers missing")
    collect_body = TEXT[TEXT.index('_menu_collect_status()'):TEXT.index('_menu_render()')]
    for mod in ['argo', 'ff', 'reality', 'vltcp', 'vlquic', 'cforigin', 'socks']:
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
    for marker in ['# core/global actions', '# module menu entrypoints', '# shared runtime actions', '# lifecycle actions', '# uninstall/update-port actions', '# field/config update actions', '# key/toggle actions', '# complex/specialized actions']:
        assert_true(marker in dispatch_body, f"module_dispatch should be grouped for readability: {marker}")
    xray_install_body = TEXT[TEXT.index('module_xray_install()'):TEXT.index('\n}\n', TEXT.index('module_xray_install()'))]
    xray_uninstall_body = TEXT[TEXT.index('module_xray_uninstall()'):TEXT.index('\n}\n', TEXT.index('module_xray_uninstall()'))]
    config_uuid_body = TEXT[TEXT.index('module_config_update_uuid()'):TEXT.index('\n}\n', TEXT.index('module_config_update_uuid()'))]
    config_shortcut_body = TEXT[TEXT.index('module_config_update_shortcut()'):TEXT.index('\n}\n', TEXT.index('module_config_update_shortcut()'))]
    assert_true('exec_install()' not in TEXT and 'exec_install' not in xray_install_body, "xray install should call module_xray_install_core, not exec_install")
    assert_true('module_xray_install_core()' in TEXT and 'install_plan_menu' in xray_install_body, "xray install should route through the install plan menu and ultimately reuse the shared install core")
    assert_true('install_execute_current_plan()' in TEXT and 'module_xray_install_core' in TEXT[TEXT.index('install_execute_current_plan()'):TEXT.index('\n}\n', TEXT.index('install_execute_current_plan()'))], "install plan executor should reuse module_xray_install_core")
    assert_true('_menu_do_install()' not in TEXT and '_menu_do_install' not in xray_install_body, "xray install workflow should live in module_xray_install, not a menu helper wrapper")
    assert_true('exec_uninstall()' not in TEXT and 'exec_uninstall' not in xray_uninstall_body, "xray uninstall workflow should live in module_xray_uninstall, not a wrapper")
    assert_true('exec_update_uuid()' not in TEXT and 'exec_update_uuid' not in config_uuid_body, "config UUID workflow should live in module_config_update_uuid, not a wrapper")
    assert_true('exec_update_shortcut()' not in TEXT and 'exec_update_shortcut' not in config_shortcut_body, "config shortcut workflow should live in module_config_update_shortcut, not a wrapper")
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
    argo_update_port_body = TEXT[TEXT.index('module_argo_update_port()'):TEXT.index('\n}\n', TEXT.index('module_argo_update_port()'))]
    assert_true('exec_update_argo_port()' not in TEXT and 'exec_update_argo_port' not in argo_update_port_body, "Argo port workflow should live in module_argo_update_port, not an exec wrapper")
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
    assert_true('_module_persist_after_optional_apply()' in TEXT, "enabled-only update persistence should use shared optional-apply commit helper")
    for fn in ['module_reality_update_transport()', 'module_vltcp_update_listen()', 'module_vlquic_update_listen()', 'module_cforigin_update_protocol()', 'module_cforigin_update_path()', 'module_cforigin_update_listen()']:
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
    assert_true('_menu_update_port vlquic udp udp' in TEXT, "VLQUIC management port input must preserve UDP conflict checks")


def test_state_schema_and_plugin_permission_hardening():
    assert_true('.ports = {"argo":18888,"ff":8080,"reality":443,"vltcp":1234,"vlquic":443,"cforigin":28888,"socks":1080}' in TEXT, "ports schema initialization must include cforigin and socks")
    assert_true('_plugin_path_safe()' in TEXT and 'stat -c' in TEXT and '_plugin_path_safe "${PLUGIN_DIR}"' in TEXT, "plugin loader must enforce ownership/mode before source")
    assert_true('val_port "${_value}"' in TEXT and 'legacy 端口字段非法' in TEXT, "legacy port migration must validate bad values explicitly")


def test_commit_helpers_fail_closed_on_firewall_reconcile():
    for fn in ['_commit', '_module_enable_commit', '_module_disable_commit']:
        m = re.search(rf"{re.escape(fn)}\(\) \{{(?P<body>.*?)\n\}}", TEXT, re.S)
        assert_true(m, f'{fn} function missing')
        body = m.group('body')
        assert_true('fw_reconcile || return 1' in body, f'{fn} must fail closed if firewall reconciliation fails')


def test_socks5_module_option_and_plugin_contract():
    assert_true('_plugin_write_socks()' in TEXT and '_plugin_write_socks' in TEXT[TEXT.index('plugin_install_builtins()'):TEXT.index('# ==============================================================================', TEXT.index('plugin_install_builtins()'))], "SOCKS5 built-in plugin must be installed")
    assert_true('_MODULE_IDS="argo ff reality vltcp vlquic cforigin socks"' in TEXT, "module registry must include socks")
    assert_true('socks)    printf \'SOCKS5\'' in TEXT, "SOCKS5 label missing")
    assert_true('module_summary socks' in TEXT and '_MENU_SD=$(module_summary socks)' in TEXT, "main status must summarize socks")
    assert_true('socks:menu)     manage_socks' in TEXT, "SOCKS5 menu must route through dispatcher")
    for token in ['socks:enable)', 'socks:disable)', 'socks:uninstall)', 'socks:update_port)', 'socks:update_listen)', 'socks:update_auth)', 'socks:show)']:
        assert_true(token in TEXT, f"SOCKS5 dispatch route missing: {token}")
    for fn in ['ask_socks_mode()', 'manage_socks()', 'module_socks_enable()', 'module_socks_disable()', 'module_socks_uninstall()', 'module_socks_update_port()', 'module_socks_update_listen()', 'module_socks_update_auth()']:
        assert_true(fn in TEXT, f"SOCKS5 helper missing: {fn}")
    assert_true('"socks":   1080' in TEXT and '"socks": {' in TEXT, "state schema must include socks port/config")
    socks_plugin = TEXT[TEXT.index('_plugin_write_socks()'):TEXT.index('_plugin_write_cforigin()', TEXT.index('_plugin_write_socks()'))]
    for token in ['_plg_socks_inbound()', 'protocol:"socks"', 'auth:"password"', 'accounts:[{user:$user, pass:$pass}]', '_plg_socks_ports()', '_plg_socks_link()']:
        assert_true(token in socks_plugin, f"SOCKS5 plugin token missing: {token}")
    assert_true('_menu_update_port socks tcp' in TEXT, "SOCKS5 port update must use TCP conflict checks")


def test_socks5_link_is_generated_and_displayed():
    assert_true("grep -E '^(vless|socks)://'" in TEXT, "node output must include v2rayN-compatible SOCKS links, not only vless links")
    socks_plugin = TEXT[TEXT.index('_plugin_write_socks()'):TEXT.index('_plugin_write_cforigin()', TEXT.index('_plugin_write_socks()'))]
    assert_true("socks://%s@%s:%s#SOCKS5" in socks_plugin, "SOCKS plugin should generate v2rayN-compatible socks:// base64(user:pass) links")
    assert_true("base64" in socks_plugin and "tr -d '=\\n'" in socks_plugin, "SOCKS credentials must be URL-safe base64(user:pass) without padding")
    assert_true('protocol:"socks"' in socks_plugin and 'auth:"password"' in socks_plugin, "SOCKS inbound should follow reference socks password-auth implementation")


def test_install_plan_menu_becomes_default_install_entry():
    assert_true('install_plan_reset_defaults()' in TEXT, "install plan reset helper missing")
    assert_true('install_plan_render_summary()' in TEXT, "install plan summary renderer missing")
    assert_true('install_plan_validate()' in TEXT, "install plan validator missing")
    assert_true('install_execute_current_plan()' in TEXT, "shared install executor missing")
    assert_true('install_plan_menu()' in TEXT, "install plan menu missing")
    body = TEXT[TEXT.index('module_xray_install()'):TEXT.index('\n}\n', TEXT.index('module_xray_install()'))]
    for token in ['install_plan_reset_defaults', 'install_plan_menu']:
        assert_true(token in body, f"module_xray_install should route through {token}")
    for forbidden in ['ask_argo_mode', 'ask_freeflow_mode', 'ask_reality_mode', 'ask_vltcp_mode', 'ask_socks_mode', 'ask_vlquic_mode', 'ask_cforigin_mode']:
        assert_true(forbidden not in body, f"default install entry should not directly chain {forbidden}")
    plan_menu = TEXT[TEXT.index('install_plan_menu()'):TEXT.index('\n}\n', TEXT.index('install_plan_menu()'))]
    for marker in ['1) install_plan_configure_argo', '2) install_plan_configure_freeflow', '3) install_plan_configure_reality', '4) ask_vltcp_mode', '5) ask_socks_mode', '6) ask_vlquic_mode', '7) ask_cforigin_mode', '10) install_plan_validate', '11)', 'install_execute_current_plan && return 0']:
        assert_true(marker in plan_menu, f"install plan menu route missing: {marker}")


def test_cli_reality_tcp_preset_entry_exists_and_uses_shared_executor():
    for fn in ['usage()', 'parse_args()', 'cli_install()', 'cli_dispatch()', 'preset_apply_reality_tcp_default()', 'reality_pick_default_tcp_port()']:
        assert_true(fn in TEXT, f"CLI helper missing: {fn}")
    parse_body = TEXT[TEXT.index('parse_args()'):TEXT.index('\n}\n', TEXT.index('parse_args()'))]
    for token in ['_CLI_ACTION="menu"', '[ "$#" -eq 0 ] && return 0', 'reality)', '未知参数: $1']:
        assert_true(token in parse_body, f"parse_args token missing: {token}")
    cli_install_body = TEXT[TEXT.index('cli_install()'):TEXT.index('\n}\n', TEXT.index('cli_install()'))]
    for token in ['preset_apply_reality_tcp_default', 'install_execute_current_plan']:
        assert_true(token in cli_install_body, f"cli_install token missing: {token}")
    preset_body = TEXT[TEXT.index('preset_apply_reality_tcp_default()'):TEXT.index('\n}\n', TEXT.index('preset_apply_reality_tcp_default()'))]
    for token in ['.reality.enabled = true', '.reality.network = "tcp"', '.argo.enabled = false', '.ff.enabled = false', '.vltcp.enabled = false', '.socks.enabled = false', '.vlquic.enabled = false', '.cforigin.enabled = false']:
        assert_true(token in preset_body, f"reality tcp preset missing: {token}")
    assert_true('reality_pick_default_tcp_port' in preset_body and '.ports.reality = ($p|tonumber)' in preset_body, "reality preset should set port through auto-selection helper")
    pick_body = TEXT[TEXT.index('reality_pick_default_tcp_port()'):TEXT.index('\n}\n', TEXT.index('reality_pick_default_tcp_port()'))]
    for token in ['local _preferred=443', 'port_mgr_in_use "${_preferred}"', 'port_mgr_random_proto tcp', '自动改用随机端口']:
        assert_true(token in pick_body, f"reality default port helper token missing: {token}")
    main_body = TEXT[TEXT.index('main()'):TEXT.index('if [ "${BASH_SOURCE[0]}" = "$0" ]; then', TEXT.index('main()'))]
    assert_true('cli_dispatch "$@"' in main_body, "main should route through cli_dispatch")
    out = run_bash("""
        source ./xray_2go.sh
        st_init
        parse_args reality
        printf 'alias_action=%s\n' "${_CLI_ACTION}"
        preset_apply_reality_tcp_default
        printf 'argo=%s reality=%s net=%s ff=%s socks=%s vlquic=%s cforigin=%s port=%s\n' \
            "$(st_get '.argo.enabled')" "$(st_get '.reality.enabled')" "$(st_get '.reality.network')" \
            "$(st_get '.ff.enabled')" "$(st_get '.socks.enabled')" "$(st_get '.vlquic.enabled')" \
            "$(st_get '.cforigin.enabled')" "$(port_of reality)"
    """)
    assert_true('alias_action=install' in out, "reality should enter install mode")
    assert_true('reality=true net=tcp' in out and 'port=443' in out, "reality tcp preset should apply the expected default state")


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


def main():
    tests = [v for k, v in globals().items() if k.startswith("test_")]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")


if __name__ == "__main__":
    main()
