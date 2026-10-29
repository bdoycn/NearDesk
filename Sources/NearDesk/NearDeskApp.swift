// Copyright 2026 NearDesk Contributors
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@main
struct NearDeskApp: App {
    var body: some Scene {
        WindowGroup("NearDesk") {
            RootView()
        }
        .defaultSize(width: 1100, height: 720)
    }
}
