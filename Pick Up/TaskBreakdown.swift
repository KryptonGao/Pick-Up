import Foundation

enum TaskBreakdownError: LocalizedError, Equatable {
    case emptyTask
    case tooLong
    case invalidResult

    var errorDescription: String? {
        switch self {
        case .emptyTask: "请先写下一件想开始的事。"
        case .tooLong: "任务描述最多 2,000 个字符，请缩短后再试。"
        case .invalidResult: "没有得到完整的 3–5 个步骤。你的原始任务仍然保留。"
        }
    }
}

protocol TaskBreakdownProviding: Sendable {
    func breakdown(task: String, clarification: String?) async throws -> TaskBreakdownResult
}

struct LocalTaskBreakdownService: TaskBreakdownProviding {
    func breakdown(task: String, clarification: String?) async throws -> TaskBreakdownResult {
        let cleanTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTask.isEmpty else { throw TaskBreakdownError.emptyTask }
        guard cleanTask.count <= 2_000 else { throw TaskBreakdownError.tooLong }

        if clarification == nil, needsClarification(cleanTask) {
            return TaskBreakdownResult(
                clarificationQuestion: "完成这件事后，你希望手上有什么可见结果？",
                steps: []
            )
        }

        let output = clarification?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TaskBreakdownResult(
            clarificationQuestion: nil,
            steps: drafts(for: cleanTask, desiredOutput: output?.isEmpty == false ? output : nil)
        )
    }

    private func needsClarification(_ task: String) -> Bool {
        let concreteMarkers = [
            "写", "读", "整理", "准备", "制作", "完成", "回复", "发送", "检查", "修改",
            "汇报", "报告", "文档", "邮件", "论文", "清单", "代码", "演示", "表格"
        ]
        return !concreteMarkers.contains(where: task.contains)
    }

    private func drafts(for task: String, desiredOutput: String?) -> [TaskStepDraft] {
        let context = desiredOutput.map { "，目标产出：\($0)" } ?? ""

        if contains(task, any: ["读", "阅读", "论文", "文章", "调研", "研究"]) {
            return [
                draft("打开材料并写下本次要回答的一个问题", 5, ["阅读材料"], "问题已经写成一句话"),
                draft("阅读第一小节并标记三个关键信息", 15, ["阅读材料", "标记工具"], "已标出三个可核对的信息"),
                draft("用自己的话记录一段简短理解", 10, ["笔记"], "留下至少三句话的笔记"),
                draft("检查笔记是否回答了最初的问题", 5, ["问题与笔记"], "明确写下答案或下一处要查的内容")
            ]
        }

        if contains(task, any: ["写", "报告", "论文", "文档", "邮件", "方案"]) {
            return [
                draft("新建文档并写下目标读者和产出", 5, ["空白文档"], "文档顶部有读者与产出说明\(context)"),
                draft("列出三个必须覆盖的要点", 10, ["已有材料"], "文档中已有三个要点"),
                draft("先完成第一个要点的粗稿", 20, ["要点清单", "参考资料"], "第一个要点形成可阅读段落"),
                draft("快速检查并标记下一处要继续的位置", 5, ["当前草稿"], "留下一个清楚的下一步")
            ]
        }

        if contains(task, any: ["汇报", "演示", "会议", "准备", "分享"]) {
            return [
                draft("写下一句话的汇报目标", 5, ["任务要求"], "目标能说明听众要知道或决定什么\(context)"),
                draft("收集现有材料并放到一个位置", 10, ["相关文件或链接"], "所需材料集中可访问"),
                draft("搭出开场、主体、结尾三个部分", 15, ["演示文档"], "三个部分都有标题和一个要点"),
                draft("完成最重要的一页或一段", 20, ["核心数据或论据"], "核心内容已经可展示"),
                draft("通读一次并写下下一步修改", 10, ["当前版本"], "记录不超过三项修改")
            ]
        }

        if contains(task, any: ["整理", "收拾", "归档", "分类"]) {
            return [
                draft("划定这次只处理的一个范围", 5, ["待整理内容"], "范围清楚且能在一轮内处理"),
                draft("把内容分成保留、处理、暂不决定三类", 15, ["三个临时分类"], "当前范围全部进入一类"),
                draft("先完成保留类的命名和归位", 15, ["目标位置"], "保留内容可以重新找到"),
                draft("记录剩余两类的下一步", 5, ["简短清单"], "每类都有一个后续动作")
            ]
        }

        if contains(task, any: ["回复", "联系", "沟通", "发送", "预约"]) {
            return [
                draft("写下这次沟通希望得到的结果", 5, ["沟通背景"], "结果可以用一句话说明\(context)"),
                draft("列出对方需要知道的三条信息", 10, ["相关事实或文件"], "三条信息完整且可核对"),
                draft("写出一版不求完美的消息", 10, ["信息清单"], "消息包含请求和下一步"),
                draft("检查收件人、附件和语气", 5, ["消息草稿"], "内容已准备好由你决定是否发送")
            ]
        }

        return [
            draft("写下这件事完成时可以看到的结果", 5, ["任务描述"], "结果具体到可以判断是否完成\(context)"),
            draft("列出开始前真正需要的材料", 5, ["简短清单"], "材料不超过五项"),
            draft("完成一个十分钟内可见的小版本", 10, ["所需材料"], "已经产生一个可以检查的结果"),
            draft("检查当前结果并写下唯一的下一步", 5, ["当前结果"], "下一步以具体动词开头")
        ]
    }

    private func contains(_ value: String, any candidates: [String]) -> Bool {
        candidates.contains(where: value.contains)
    }

    private func draft(
        _ action: String,
        _ minutes: Int,
        _ materials: [String],
        _ criteria: String
    ) -> TaskStepDraft {
        TaskStepDraft(
            action: action,
            estimatedMinutes: minutes,
            materials: materials,
            completionCriteria: criteria
        )
    }
}
