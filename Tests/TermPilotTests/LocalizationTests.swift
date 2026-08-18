import Foundation
@testable import TermPilotApp
import XCTest

final class LocalizationTests: XCTestCase {
    func testTopTabQuickSwitcherUsesApplicationLanguageBundles() {
        let chinese = AppResourceLocator.localizedBundle(
            for: "zh-Hans"
        )
        let english = AppResourceLocator.localizedBundle(for: "en")
        let expectedChinese = [
            "Search hosts or local terminal...": "搜索主机或本地终端...",
            "Open Quick Switcher": "打开快速切换",
            "Hosts": "主机",
            "Local Shells": "本地终端",
            "Local Terminal": "本地终端",
            "No matching hosts or local terminal": "没有匹配的主机或本地终端",
        ]

        for (key, expected) in expectedChinese {
            XCTAssertEqual(localized(key, in: chinese), expected)
            XCTAssertEqual(localized(key, in: english), key)
        }
    }

    func testTerminalContextMenuUsesApplicationLanguageBundles() {
        let chinese = AppResourceLocator.localizedBundle(
            for: "zh-Hans"
        )
        let english = AppResourceLocator.localizedBundle(for: "en")
        let expectedChinese = [
            "Copy": "复制",
            "Paste": "粘贴",
            "Paste Selected Text": "粘贴选中文本",
        ]

        for (key, expected) in expectedChinese {
            XCTAssertEqual(localized(key, in: chinese), expected)
            XCTAssertEqual(localized(key, in: english), key)
        }
    }

    func testQuickConnectUsesApplicationLanguageBundles() {
        let chinese = AppResourceLocator.localizedBundle(
            for: "zh-Hans"
        )
        let english = AppResourceLocator.localizedBundle(for: "en")

        XCTAssertEqual(
            localized("Quick Connect", in: chinese),
            "快速连接"
        )
        XCTAssertEqual(
            localized("Custom Credential", in: chinese),
            "自定义凭证"
        )
        XCTAssertEqual(
            localized("Server Tools", in: chinese),
            "服务器工具"
        )
        XCTAssertEqual(
            localized("Privilege Escalation", in: chinese),
            "提权方式"
        )
        XCTAssertEqual(
            localized("Quick Connect", in: english),
            "Quick Connect"
        )
        XCTAssertEqual(
            localized("Server Tools", in: english),
            "Server Tools"
        )
    }

    func testGeneralSettingsUsesApplicationLanguageBundles() {
        let chinese = AppResourceLocator.localizedBundle(
            for: "zh-Hans"
        )
        let english = AppResourceLocator.localizedBundle(for: "en")
        let expectedChinese = [
            "Automatically accept SSH fingerprints": "自动接受 SSH 指纹",
            "When enabled, SSH fingerprints are accepted automatically. Turn it off to confirm fingerprints manually.": "开启后会自动接受 SSH 指纹。关闭后需要手动确认指纹。",
            "SFTP": "SFTP",
            "Show Hidden Files": "显示隐藏文件",
            "File Transfer Concurrency": "文件传输并发数",
            "Single-File Chunk Concurrency": "单文件分块并发数",
            "Chunk Size": "分块大小",
            "Transfer Connection Keep-Alive": "传输连接保活时间",
        ]

        for (key, expected) in expectedChinese {
            XCTAssertEqual(localized(key, in: chinese), expected)
            XCTAssertEqual(localized(key, in: english), key)
        }
    }

    func testBackupSettingsUsesApplicationLanguageBundles() {
        let chinese = AppResourceLocator.localizedBundle(
            for: "zh-Hans"
        )
        let english = AppResourceLocator.localizedBundle(for: "en")
        let expectedChinese = [
            "Backup": "备份",
            "Encrypted Backup": "加密备份",
            "Export Backup": "导出备份",
            "Import Backup": "导入备份",
            "Backup Password": "备份密码",
            "Confirm Backup Password": "确认备份密码",
            "The backup password is incorrect or the file has been modified.": "备份密码错误，或文件已被修改。",
        ]

        for (key, expected) in expectedChinese {
            XCTAssertEqual(localized(key, in: chinese), expected)
            XCTAssertEqual(localized(key, in: english), key)
        }
    }

    func testAboutSettingsUsesApplicationLanguageBundles() {
        let chinese = AppResourceLocator.localizedBundle(
            for: "zh-Hans"
        )
        let english = AppResourceLocator.localizedBundle(for: "en")
        let expectedChinese = [
            "About": "关于",
            "About TermPilot": "关于 TermPilot",
            "Version %@ (%@)": "版本 %@ (%@)",
        ]

        for (key, expected) in expectedChinese {
            XCTAssertEqual(localized(key, in: chinese), expected)
            XCTAssertEqual(localized(key, in: english), key)
        }
    }

    func testHostEditorUsesApplicationLanguageBundles() {
        let chinese = AppResourceLocator.localizedBundle(
            for: "zh-Hans"
        )
        let english = AppResourceLocator.localizedBundle(for: "en")
        let expectedChinese = [
            "New Host": "新建主机",
            "Edit Host": "编辑主机",
            "Credential": "凭证",
            "Authentication": "认证方式",
            "Address": "地址",
            "IP or Hostname": "IP 或 主机名",
            "Colors & Icons": "颜色与图标",
            "Auto Detect": "自动探测",
            "File Protocol": "文件协议",
            "Server Tools": "服务器工具",
            "Privilege Escalation": "提权方式",
            "Uses the selected sudo or su method for SFTP, System, and Docker.": "SFTP、系统监控和 Docker 使用所选的 sudo 或 su 提权。",
            "Proxy": "代理",
            "Use Proxy": "使用代理",
            "Save": "保存",
            "Cancel": "取消",
        ]

        for (key, expected) in expectedChinese {
            XCTAssertEqual(localized(key, in: chinese), expected)
            XCTAssertEqual(localized(key, in: english), key)
        }
    }

    func testHostGroupContextMenuUsesApplicationLanguageBundles() {
        let chinese = AppResourceLocator.localizedBundle(
            for: "zh-Hans"
        )
        let english = AppResourceLocator.localizedBundle(for: "en")
        let expectedChinese = [
            "New Host in This Group": "在此分组中新建主机",
            "New Subgroup": "新建子分组",
            "Rename Group": "重命名分组",
            "Delete Group": "删除分组",
            "Group name is required.": "分组名称不能为空。",
            "Group names cannot contain slash characters.": "分组名称不能包含斜杠字符。",
            "A group with this name already exists here.": "当前位置已存在同名分组。",
        ]

        for (key, expected) in expectedChinese {
            XCTAssertEqual(localized(key, in: chinese), expected)
            XCTAssertEqual(localized(key, in: english), key)
        }
    }

    func testHostBatchManagementUsesApplicationLanguageBundles() {
        let chinese = AppResourceLocator.localizedBundle(
            for: "zh-Hans"
        )
        let english = AppResourceLocator.localizedBundle(for: "en")
        let expectedChinese = [
            "Select hosts or groups, then switch their group or manage their proxy.": "选择主机或目录后，可切换分组或管理代理。",
            "Assign Proxy": "分配代理",
            "Disable Proxy": "关闭代理",
        ]

        for (key, expected) in expectedChinese {
            XCTAssertEqual(localized(key, in: chinese), expected)
            XCTAssertEqual(localized(key, in: english), key)
        }
    }

    func testCredentialEditorUsesApplicationLanguageBundles() {
        let chinese = AppResourceLocator.localizedBundle(
            for: "zh-Hans"
        )
        let english = AppResourceLocator.localizedBundle(for: "en")
        let expectedChinese = [
            "Label *": "标签 *",
            "Username *": "用户名 *",
            "Password *": "密码 *",
            "Credential label": "凭证标签",
            "Create Credential": "创建凭证",
            "Delete Credential": "删除凭证",
            "Affected Hosts": "关联主机",
            "Export to Hosts": "导出到主机",
            "Protect with passphrase": "使用密码短语保护",
            "Credential created successfully.": "凭证创建成功。",
        ]

        for (key, expected) in expectedChinese {
            XCTAssertEqual(localized(key, in: chinese), expected)
            XCTAssertEqual(localized(key, in: english), key)
        }
    }

    func testScriptEditorUsesApplicationLanguageBundles() {
        let chinese = AppResourceLocator.localizedBundle(
            for: "zh-Hans"
        )
        let english = AppResourceLocator.localizedBundle(for: "en")
        let expectedChinese = [
            "Title *": "标题 *",
            "Script title": "脚本标题",
            "Content": "内容",
            "Create and manage shell scripts for terminal sessions.": "创建和管理用于终端会话的 Shell 脚本。",
        ]

        for (key, expected) in expectedChinese {
            XCTAssertEqual(localized(key, in: chinese), expected)
            XCTAssertEqual(localized(key, in: english), key)
        }
    }

    func testTerminalAutocompleteUsesApplicationLanguageBundles() {
        let chinese = AppResourceLocator.localizedBundle(
            for: "zh-Hans"
        )
        let english = AppResourceLocator.localizedBundle(for: "en")
        let expectedChinese = [
            "Autocomplete": "自动补全",
            "Enable Autocomplete": "启用自动补全",
            "Inline Suggestions": "行内建议",
            "Popup Menu": "弹出菜单",
        ]

        for (key, expected) in expectedChinese {
            XCTAssertEqual(localized(key, in: chinese), expected)
            XCTAssertEqual(localized(key, in: english), key)
        }
    }

    func testSFTPConflictDialogUsesApplicationLanguageBundles() {
        let chinese = AppResourceLocator.localizedBundle(
            for: "zh-Hans"
        )
        let english = AppResourceLocator.localizedBundle(for: "en")
        let expectedChinese = [
            "File Conflict": "文件冲突",
            "Batch upload name conflicts detected": "检测到批量上传同名冲突",
            "Choose how to handle each item, then start the upload.": "请选择每一项或批量处理方式，再开始上传。",
            "Conflicts: %@": "冲突数量：%@",
            "Default action for all conflicts:": "所有冲突统一处理：",
            "Remote Path": "远端路径",
            "Action": "处理",
            "Overwrite": "覆盖",
            "Create Copy": "创建副本",
            "Start Upload": "开始上传",
            "An item with the same name already exists at the destination.": "目标位置已存在同名项目。",
            "Existing item": "已有项目",
            "New item": "新项目",
            "Apply this action to all %@ remaining conflicts": "将此操作应用到剩余的 %@ 个同类冲突",
        ]

        for (key, expected) in expectedChinese {
            XCTAssertEqual(localized(key, in: chinese), expected)
            XCTAssertEqual(localized(key, in: english), key)
        }
    }

    private func localized(
        _ key: String,
        in bundle: Bundle
    ) -> String {
        NSLocalizedString(
            key,
            bundle: bundle,
            value: key,
            comment: ""
        )
    }
}
