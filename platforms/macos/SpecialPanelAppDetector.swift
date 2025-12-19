//
//  SpecialPanelAppDetector.swift
//  GoNhanh
//
//  Detects special panel apps (Spotlight, Raycast) that don't trigger
//  NSWorkspaceDidActivateApplicationNotification
//

import Cocoa
import ApplicationServices

/// Detects special panel/overlay apps like Spotlight and Raycast
class SpecialPanelAppDetector {
    
    // MARK: - Properties
    
    /// List of special panel app bundle identifiers
    static let specialPanelApps: [String] = [
        "com.apple.Spotlight",
        "com.raycast.macos",
        "com.apple.inputmethod.EmojiFunctionRowItem"
    ]
    
    /// Last detected frontmost app (for tracking changes)
    private static var lastFrontMostApp: String = ""
    
    // MARK: - Detection Methods
    
    /// Check if a bundle ID is a special panel app
    static func isSpecialPanelApp(_ bundleId: String?) -> Bool {
        guard let bundleId = bundleId else { return false }
        return specialPanelApps.contains { bundleId.hasPrefix($0) || bundleId == $0 }
    }
    
    /// Get the currently active special panel app (if any)
    /// Uses CGWindowListCopyWindowInfo to detect overlay windows
    static func getActiveSpecialPanelApp() -> String? {
        // Method 1: Use CGWindowListCopyWindowInfo to find on-screen windows
        // This is more reliable than Accessibility API for Spotlight/Raycast
        if let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for window in windowList {
                guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                      let windowLayer = window[kCGWindowLayer as String] as? Int else {
                    continue
                }
                
                // Spotlight and Raycast typically use high window layers (above normal windows)
                // Layer 0 = normal windows, higher = overlay windows
                if windowLayer > 0 {
                    if let app = NSRunningApplication(processIdentifier: ownerPID),
                       let bundleId = app.bundleIdentifier {
                        if isSpecialPanelApp(bundleId) {
                            return bundleId
                        }
                    }
                }
            }
        }
        
        // Method 2: Check system-wide focused element
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        let focusError = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        
        if focusError == .success, let element = focusedElement {
            var pid: pid_t = 0
            if AXUIElementGetPid(element as! AXUIElement, &pid) == .success, pid > 0 {
                if let app = NSRunningApplication(processIdentifier: pid),
                   let bundleId = app.bundleIdentifier {
                    if isSpecialPanelApp(bundleId) {
                        return bundleId
                    }
                }
            }
        }
        
        // Method 3: Check each special panel app directly using Accessibility API
        for panelAppId in specialPanelApps {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: panelAppId)
            
            for app in runningApps {
                let appElement = AXUIElementCreateApplication(app.processIdentifier)
                
                // Try kAXFocusedWindowAttribute
                var focusedWindow: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
                
                if error == .success && focusedWindow != nil {
                    return panelAppId
                }
                
                // Try kAXWindowsAttribute
                var windows: CFTypeRef?
                let windowsError = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windows)
                
                if windowsError == .success, let windowArray = windows as? [AXUIElement], !windowArray.isEmpty {
                    return panelAppId
                }
                
                // Check if app is active
                if app.isActive {
                    return panelAppId
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Smart Switch Integration
    
    /// Check if a special panel app has become active or inactive
    /// Returns: (appChanged: Bool, newBundleId: String?, isSpecialPanelApp: Bool)
    static func checkForAppChange() -> (appChanged: Bool, newBundleId: String?, isSpecialPanelApp: Bool) {
        // Check if a special panel app is currently active
        let activePanelApp = getActiveSpecialPanelApp()
        
        if let panelApp = activePanelApp {
            // A special panel app is active
            if panelApp != lastFrontMostApp {
                lastFrontMostApp = panelApp
                return (true, panelApp, true)
            }
            return (false, panelApp, true)
        }
        
        // No special panel app is active
        // If we were previously in a special panel app, we've returned to a normal app
        if isSpecialPanelApp(lastFrontMostApp) {
            let workspaceApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if let app = workspaceApp {
                lastFrontMostApp = app
                return (true, app, false)
            }
        }
        
        return (false, nil, false)
    }
    
    /// Update the last frontmost app (call this when NSWorkspaceDidActivateApplicationNotification fires)
    static func updateLastFrontMostApp(_ bundleId: String) {
        lastFrontMostApp = bundleId
    }
    
    /// Get the last known frontmost app
    static func getLastFrontMostApp() -> String {
        return lastFrontMostApp
    }
}
