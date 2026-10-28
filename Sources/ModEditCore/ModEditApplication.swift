import AppKit

/// The application entry point.
///
/// This is deliberately a small AppKit shell: a document-based app needs
/// `NSDocument`, `NSDocumentController` and a window responder chain. The
/// editor itself is still SwiftUI inside `ModEditWindowController`.
public enum ModEditApplication {
    /// Runs the application. Called by the executable target's `@main`.
    @MainActor
    public static func run() {
        let application = NSApplication.shared
        let delegate = ModEditApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class ModEditApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Force the Objective-C runtime to register the class named by
        // `NSDocumentClass` in Info.plist. The string reference alone does not
        // keep a Swift class from being stripped from the linked image.
        _ = ModEditDocument.self
        _ = NSDocumentController.shared
        installMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag, NSDocumentController.shared.documents.isEmpty {
            NSDocumentController.shared.newDocument(nil)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) {
                document, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }

    // MARK: Main menu

    private func installMainMenu() {
        let mainMenu = NSMenu(title: "Main Menu")
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(windowMenuItem())
        NSApp.mainMenu = mainMenu
    }

    private func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "ModEdit")
        item.submenu = menu

        menu.addItem(menuItem("About ModEdit",
                              action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                              target: NSApp))
        menu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        menu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu

        menu.addItem(.separator())
        menu.addItem(menuItem("Hide ModEdit",
                              action: #selector(NSApplication.hide(_:)),
                              keyEquivalent: "h",
                              target: NSApp))
        let hideOthers = menuItem("Hide Others",
                                  action: #selector(NSApplication.hideOtherApplications(_:)),
                                  keyEquivalent: "h",
                                  target: NSApp)
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(menuItem("Show All",
                              action: #selector(NSApplication.unhideAllApplications(_:)),
                              target: NSApp))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit ModEdit",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q",
                              target: NSApp))
        return item
    }

    private func fileMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")
        item.submenu = menu

        menu.addItem(menuItem("New",
                              action: #selector(NSDocumentController.newDocument(_:)),
                              keyEquivalent: "n",
                              target: NSDocumentController.shared))
        menu.addItem(menuItem("Open…",
                              action: #selector(NSDocumentController.openDocument(_:)),
                              keyEquivalent: "o",
                              target: NSDocumentController.shared))

        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.addItem(menuItem("Clear Menu",
                                    action: #selector(NSDocumentController.clearRecentDocuments(_:)),
                                    target: NSDocumentController.shared))
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        menu.addItem(.separator())
        menu.addItem(menuItem("Close",
                              action: #selector(NSWindow.performClose(_:)),
                              keyEquivalent: "w"))

        menu.addItem(.separator())
        menu.addItem(menuItem("Save",
                              action: #selector(NSDocument.save(_:)),
                              keyEquivalent: "s"))
        let saveAs = menuItem("Save As…",
                              action: #selector(NSDocument.saveAs(_:)),
                              keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(saveAs)
        menu.addItem(menuItem("Revert to Saved",
                              action: #selector(NSDocument.revertToSaved(_:))))
        return item
    }

    private func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        item.submenu = menu

        menu.addItem(menuItem("Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = menuItem("Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(menuItem("Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        menu.addItem(menuItem("Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        menu.addItem(menuItem("Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        menu.addItem(menuItem("Delete", action: #selector(NSText.delete(_:))))
        menu.addItem(menuItem("Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        menu.addItem(.separator())

        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        findItem.submenu = findMenu
        findMenu.addItem(menuItem("Find…",
                                  action: #selector(NSTextView.performFindPanelAction(_:)),
                                  keyEquivalent: "f",
                                  tag: Int(NSFindPanelAction.showFindPanel.rawValue)))
        findMenu.addItem(menuItem("Find Next",
                                  action: #selector(NSTextView.performFindPanelAction(_:)),
                                  keyEquivalent: "g",
                                  tag: Int(NSFindPanelAction.next.rawValue)))
        let findPrevious = menuItem("Find Previous",
                                    action: #selector(NSTextView.performFindPanelAction(_:)),
                                    keyEquivalent: "g",
                                    tag: Int(NSFindPanelAction.previous.rawValue))
        findPrevious.keyEquivalentModifierMask = [.command, .shift]
        findMenu.addItem(findPrevious)
        menu.addItem(findItem)
        return item
    }

    private func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        item.submenu = menu

        menu.addItem(menuItem("Minimize",
                              action: #selector(NSWindow.performMiniaturize(_:)),
                              keyEquivalent: "m"))
        menu.addItem(menuItem("Zoom", action: #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(menuItem("Bring All to Front",
                              action: #selector(NSApplication.arrangeInFront(_:)),
                              target: NSApp))
        NSApp.windowsMenu = menu
        return item
    }

    private func menuItem(_ title: String,
                          action: Selector?,
                          keyEquivalent: String = "",
                          target: AnyObject? = nil,
                          tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        item.tag = tag
        return item
    }
}
