#!/usr/bin/env python3
"""Fixture-only tests for the Swift localization audit."""
import unittest
from audit_localization import audit_source, swift_literals


class LocalizationAuditTests(unittest.TestCase):
    def test_ui_copy_and_cjk_errors_are_detected(self):
        source = '''Text("Refresh")
Button("Save", action: save)
let title = "New configuration"
return "无法保存文件"
'''
        self.assertEqual([item[2] for item in audit_source(source)],
                         ["Refresh", "Save", "New configuration", "无法保存文件"])

    def test_comments_commands_and_technical_labels_are_ignored(self):
        source = '''// Text("保存")
/* Button("Save") /* Text("内层") */ */
let command = "echo 保存"
let pattern = "[中文]"
Text("PATH")
Text("CPU")
Text("128 GB")
Text("https://example.org")
Text(l10n.t("dev.shell.save"))
let processNames = ["飞书", "微信", "钉钉"]
'''
        self.assertEqual(audit_source(source), [])

    def test_raw_and_multiline_strings_are_detected(self):
        source = 'Text(#"Waiting for input"#)\nlet title = """\n尚未保存\n"""'
        findings = audit_source(source)
        self.assertEqual(findings[0][2], "Waiting for input")
        self.assertIn("尚未保存", findings[1][2])

    def test_nested_interpolation_preserves_outer_copy(self):
        source = 'Text("已保存 \\(name ?? "临时")，共 \\(count) 项")'
        literals, _ = swift_literals(source)
        self.assertEqual(literals[0].value, "已保存 <value>，共 <value> 项")
        self.assertEqual(len(audit_source(source)), 1)

    def test_bilingual_helpers_are_detected(self):
        findings = audit_source('static func choose(_ chinese: String, _ english: String) -> String {}')
        self.assertEqual(findings[0][1], "bilingual helper")

    def test_runtime_pid_label_is_technical(self):
        self.assertEqual(audit_source('Text("\\(name) · PID \\(pid)")'), [])

    def test_localized_error_english_is_detected(self):
        source = '''var errorDescription: String? {
switch self {
case .missing: return "File is unavailable."
case .changed: return L10n.shared.t("error.changed")
}
}'''
        self.assertEqual([item[2] for item in audit_source(source)], ["File is unavailable."])

    def test_conditional_labels_and_symbol_names(self):
        source = '''Button(running ? "Restart" : "Start")
DevCardTitle(symbol: active ? "terminal" : "terminal.fill", title: "Tools")
Button(action: { let command = "echo hello" }) { Text(l10n.t("action.run")) }
'''
        self.assertEqual([item[2] for item in audit_source(source)], ["Restart", "Start", "Tools"])

    def test_conditional_localization_keys_and_data_are_ignored(self):
        source = '''Text(l10n.t(active ? "state.ready" : "state.waiting"))
Text(l10n.tf("group.bytes", group.id == "shared-mcp" ? count : 0))
Text(l10n.t("service." + (["started", "stopped", "error"].contains(status) ? status : "unknown")))
Text(fields["hostname"] ?? fields["user"] ?? "")
Text(items.joined(separator: "\\n\\n"))
Text(String(format: "%.1f%%", cpu))
Text("foo.bar")
Text("CPU percentage")
'''
        self.assertEqual([item[2] for item in audit_source(source)], ["foo.bar", "CPU percentage"])


if __name__ == "__main__":
    unittest.main()
