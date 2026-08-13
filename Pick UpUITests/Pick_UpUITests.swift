import AppKit
import XCTest

final class Pick_UpUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOnboardingExplainsPrivacyAndRequiresShortcut() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        XCTAssertTrue(app.staticTexts["文字由你决定何时读取"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["onboarding.step.description"].exists)
        app.buttons["继续"].click()
        XCTAssertTrue(app.staticTexts["录制一个顺手的快捷键"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["继续"].isEnabled)
    }

    @MainActor
    func testSampleReaderSupportsCoreActions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--sample-reader"]
        app.launch()

        XCTAssertTrue(app.staticTexts["第 1 / 3 段"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["下一段"].exists)
        XCTAssertTrue(app.buttons["朗读当前段"].exists)
        XCTAssertTrue(app.buttons["标记重点"].exists)
        XCTAssertTrue(app.buttons["清除"].exists)

        app.buttons["朗读当前段"].click()
        XCTAssertTrue(
            app.sheets.buttons["同意并朗读"].waitForExistence(timeout: 2),
            app.debugDescription
        )
        app.sheets.buttons["取消"].click()
    }

    @MainActor
    func testCompactReaderKeepsControlsInsideWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--sample-reader", "--compact-window"]
        app.launch()

        XCTAssertTrue(app.staticTexts["第 1 / 3 段"].waitForExistence(timeout: 3), app.debugDescription)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists)

        let controlLabels = [
            "新建",
            "AI 阅读辅助",
            "打开设置",
            "朗读当前段",
            "朗读选中",
            "朗读全文",
            "清除"
        ]
        for label in controlLabels {
            let control = app.descendants(matching: .any)[label].firstMatch
            XCTAssertTrue(control.exists, "紧凑布局缺少控件：\(label)\n\(app.debugDescription)")
            XCTAssertTrue(
                control.isHittable,
                "紧凑布局中的控件不可操作：\(label)，控件 \(control.frame)，窗口 \(window.frame)\n\(app.debugDescription)"
            )
            XCTAssertGreaterThanOrEqual(control.frame.minX, window.frame.minX, "\(label) 从窗口左侧溢出")
            XCTAssertLessThanOrEqual(control.frame.maxX, window.frame.maxX, "\(label) 从窗口右侧溢出")
            XCTAssertGreaterThanOrEqual(control.frame.minY, window.frame.minY, "\(label) 从窗口顶部溢出")
            XCTAssertLessThanOrEqual(control.frame.maxY, window.frame.maxY, "\(label) 从窗口底部溢出")
        }

        let closeButton = window.buttons["_XCUI:CloseWindow"]
        let taskMode = app.radioButtons["任务"]
        XCTAssertTrue(closeButton.exists)
        XCTAssertTrue(taskMode.exists)
        XCTAssertGreaterThanOrEqual(
            taskMode.frame.minY,
            closeButton.frame.maxY,
            "工作台控件不得与窗口交通灯重叠"
        )
    }

    @MainActor
    func testCompletedOnboardingLaunchStillShowsWorkbench() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--compact-window"]
        app.launch()

        XCTAssertTrue(app.staticTexts["从当前文字开始"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["读取当前选区"].exists)
        XCTAssertTrue(app.buttons["从剪贴板新建"].exists)
    }

    @MainActor
    func testStandardDesktopWindowUsesDefaultSize() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding"]
        app.launch()

        let window = app.windows["Pick Up"]
        XCTAssertTrue(window.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertGreaterThanOrEqual(window.frame.width, 840)
        XCTAssertGreaterThanOrEqual(window.frame.height, 680)
        XCTAssertTrue(app.menuBars.firstMatch.exists, "标准桌面 App 应提供应用菜单栏")
        XCTAssertTrue(app.menuBars.menuBarItems["工作台"].exists, "应提供工作台主菜单")
        XCTAssertTrue(
            app.descendants(matching: .any)["workbench.sidebar.header"].exists,
            "宽窗口应展示工作台侧边栏"
        )

        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["我的任务"].waitForExistence(timeout: 2), "⌘2 应切换到任务工作台")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["从当前文字开始"].waitForExistence(timeout: 2), "⌘1 应切换回阅读工作台")
    }

    @MainActor
    func testLocalTaskCanReachCurrentStepAndFocus() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--compact-window"]
        app.launch()

        let taskMode = app.radioButtons["任务"]
        XCTAssertTrue(taskMode.waitForExistence(timeout: 3), app.debugDescription)
        taskMode.click()
        let newTask = app.buttons["新建任务"].firstMatch
        XCTAssertTrue(newTask.waitForExistence(timeout: 2))
        newTask.click()

        let editor = app.textViews["任务描述"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3), app.debugDescription)
        editor.typeText("写下周产品汇报")
        app.buttons["使用本地拆解"].click()

        XCTAssertTrue(app.staticTexts["检查步骤"].waitForExistence(timeout: 2), app.debugDescription)
        app.buttons["保存任务"].click()
        XCTAssertTrue(app.staticTexts["现在就做"].waitForExistence(timeout: 2), app.debugDescription)
        XCTAssertTrue(app.buttons["开始专注"].exists)

        let window = app.windows.firstMatch
        let compactDetailControls = [
            app.buttons["所有任务"],
            app.staticTexts["现在就做"],
            app.buttons["开始专注"]
        ]
        for control in compactDetailControls {
            XCTAssertTrue(control.exists)
            XCTAssertTrue(control.isHittable, "任务详情控件不可操作：\(control.label)")
            XCTAssertGreaterThanOrEqual(control.frame.minX, window.frame.minX)
            XCTAssertLessThanOrEqual(control.frame.maxX, window.frame.maxX)
            XCTAssertGreaterThanOrEqual(control.frame.minY, window.frame.minY)
            XCTAssertLessThanOrEqual(control.frame.maxY, window.frame.maxY)
        }
    }

    @MainActor
    func testPhase3RestoresLatestCardAndOpensTask() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--sample-phase3"]
        app.launch()

        let latestCard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '上次做到这里'")).firstMatch
        XCTAssertTrue(latestCard.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.textFields["我正在做什么"].exists)
        XCTAssertTrue(app.buttons["继续工作"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["搜索本地历史"].exists)

        app.buttons["继续工作"].click()
        XCTAssertTrue(app.staticTexts["现在就做"].waitForExistence(timeout: 2), app.debugDescription)

        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["继续与历史"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testStartHereShowsCardAndResumesTask() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--sample-relay"]
        app.launch()

        XCTAssertTrue(app.staticTexts["开始这里"].firstMatch.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["我在做什么"].waitForExistence(timeout: 2), app.debugDescription)
        XCTAssertTrue(app.staticTexts["准备产品汇报"].exists)
        let start = app.buttons["开始这一步"]
        XCTAssertTrue(start.exists, app.debugDescription)

        start.click()
        XCTAssertTrue(app.staticTexts["现在就做"].waitForExistence(timeout: 2), app.debugDescription)
    }

    @MainActor
    func testReadingToTaskPrefillsAndLinksBack() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--sample-reader"]
        app.launch()

        XCTAssertTrue(app.staticTexts["第 1 / 3 段"].waitForExistence(timeout: 3), app.debugDescription)
        let toTask = app.buttons["转为任务"]
        XCTAssertTrue(toTask.waitForExistence(timeout: 2), app.debugDescription)
        toTask.click()

        let editor = app.textViews["任务描述"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3), app.debugDescription)
        let prefilled = editor.value as? String ?? ""
        XCTAssertTrue(prefilled.contains("示例文稿"), "预填任务应包含来源提示：\(prefilled)\n\(app.debugDescription)")

        app.buttons["使用本地拆解"].click()
        XCTAssertTrue(app.staticTexts["检查步骤"].waitForExistence(timeout: 2), app.debugDescription)
        app.buttons["保存任务"].click()

        let related = app.buttons["打开相关阅读"]
        XCTAssertTrue(related.waitForExistence(timeout: 2), app.debugDescription)
        related.click()
        XCTAssertTrue(app.staticTexts["第 1 / 3 段"].waitForExistence(timeout: 2), app.debugDescription)
    }

    @MainActor
    func testCompactStartHereInsideWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "--sample-relay", "--compact-window"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3), app.debugDescription)
        let startHereRadio = app.radioButtons["开始这里"]
        XCTAssertTrue(startHereRadio.waitForExistence(timeout: 3), app.debugDescription)

        let controls = [
            startHereRadio,
            app.buttons["开始这一步"],
            app.buttons["查看历史"]
        ]
        for control in controls {
            XCTAssertTrue(control.exists, "缺少控件：\(control.label)\n\(app.debugDescription)")
            XCTAssertTrue(control.isHittable, "控件不可操作：\(control.label)，控件 \(control.frame)，窗口 \(window.frame)\n\(app.debugDescription)")
            XCTAssertGreaterThanOrEqual(control.frame.minX, window.frame.minX, "\(control.label) 从窗口左侧溢出")
            XCTAssertLessThanOrEqual(control.frame.maxX, window.frame.maxX, "\(control.label) 从窗口右侧溢出")
            XCTAssertGreaterThanOrEqual(control.frame.minY, window.frame.minY, "\(control.label) 从窗口顶部溢出")
            XCTAssertLessThanOrEqual(control.frame.maxY, window.frame.maxY, "\(control.label) 从窗口底部溢出")
        }
    }

    @MainActor
    func testAPIKeyFieldSupportsCommandPasteAndPasteButton() throws {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("sk-ui-test-not-saved", forType: .string)

        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding"]
        app.launch()

        let settingsButton = app.buttons["打开设置"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 3), app.debugDescription)
        settingsButton.click()

        var keyField = app.secureTextFields["ai.apiKey"]
        XCTAssertTrue(keyField.waitForExistence(timeout: 2), app.debugDescription)
        app.sheets.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -420)
        app.buttons["粘贴"].click()
        XCTAssertTrue(app.staticTexts["已粘贴，点击保存后才会写入钥匙串。"].waitForExistence(timeout: 2))

        app.terminate()
        app.launch()
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 3), app.debugDescription)
        settingsButton.click()
        keyField = app.secureTextFields["ai.apiKey"]
        XCTAssertTrue(keyField.waitForExistence(timeout: 2), app.debugDescription)
        app.sheets.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -420)
        keyField.click()
        keyField.typeKey("v", modifierFlags: .command)
        let saveButton = app.buttons.matching(
            NSPredicate(format: "label IN {'保存 Key', '替换 Key'} AND enabled == true")
        ).firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: 2), app.debugDescription)
    }
}
