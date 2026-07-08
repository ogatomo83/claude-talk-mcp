//
//  LoginItemManager.swift
//  claude-talk-mcp
//
//  ログイン時の自動起動（任意）を SMAppService で管理する。
//

import ServiceManagement

enum LoginItemManager {
    /// 現在ログイン項目として登録済みか。
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// ログイン時の自動起動を有効/無効にする。
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
