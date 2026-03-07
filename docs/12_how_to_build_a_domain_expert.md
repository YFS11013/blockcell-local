# 12 - 如何构建一个领域专家

Blockcell 的核心设计目标之一是成为特定领域的专家助手。本文档将指导你完成将 Blockcell 从一个通用代理转变为领域专家的完整流程。

这个过程遵循一个核心理念：**知识、工具和工作流的有机结合**。

我们将以“接触网布设”这一工程领域为例，展示每个步骤的实践。

## 核心流程概述

构建一个领域专家的过程可以分为四个主要阶段：

1.  **知识沉淀**: 建立专家所需的核心知识库。
2.  **工具开发**: 为专家打造专用的、可执行的工具。
3.  **技能编排**: 编写工作流（技能），将知识和工具串联起来解决问题。
4.  **测试验证**: 确保专家能够正确、可靠地工作。

---

### 第一阶段：知识沉淀 (Knowledge Integration)

专家首先需要理论知识。你需要将领域的规范、手册、SOP（标准作业程序）等文档化。

1.  **创建专属目录**: 在项目根目录下，创建一个 `domain_experts/` 目录，并为你的领域创建一个子目录。
    ```bash
    mkdir -p domain_experts/catenary/knowledge
    ```

2.  **编写核心知识文档**: 在 `knowledge/` 目录下，创建一个核心的 Markdown 文档（例如 `Catenary_SOP.md`）。这个文档应该包含：
    *   **核心原则**: 如规则的优先级 (P0, P1, P2)。
    *   **工作流程**: 解决问题的宏观和微观步骤。
    *   **详细规则库**: 将所有具体的计算公式、约束条件、边界值等一一列出。

这份文档是后续所有开发工作的“圣经”，也是专家系统自我解释和未来迭代的基础。

---

### 第二阶段：工具开发 (Tool Development in Rust)

接下来，我们需要将知识中的计算和操作，转化为 Blockcell 可以调用的代码。这通过在 Rust 中实现 `Tool` trait 来完成。

1.  **创建工具文件**: 在 `crates/tools/src/` 目录下，为你的领域创建一个新的 Rust 模块文件，例如 `catenary.rs`。

2.  **实现 `Tool` Trait**:
    *   创建一个结构体，例如 `CatenaryExpertTool`。
    *   为其实现 `async_trait` 的 `Tool` trait。
    *   **`schema()`**: 定义工具的名称、描述和输入/输出参数。这是 LLM 理解你工具功能的唯一入口。使用 JSON Schema 来精确描述参数，包括子命令（subcommands）、必需字段等。
    *   **`validate()`**: 在执行前，检查调用者传入的参数是否合法。
    *   **`execute()`**: 实现工具的核心逻辑。根据传入的子命令，分发到不同的内部函数进行处理，并返回结果。

    ```rust
    // In crates/tools/src/catenary.rs
    pub struct CatenaryExpertTool;

    #[async_trait]
    impl Tool for CatenaryExpertTool {
        fn schema(&self) -> ToolSchema {
            // ... returns the JSON schema for "catenary_expert" tool
        }
        
        async fn execute(&self, _ctx: ToolContext, params: Value) -> Result<Value> {
            // ... logic to dispatch based on params["subcommand"]
        }
    }
    ```

3.  **注册工具**:
    *   在 `crates/tools/src/lib.rs` 中，添加 `pub mod catenary;` 来声明新模块。
    *   在 `crates/tools/src/registry.rs` 中，导入你的工具结构体 (`use crate::catenary::CatenaryExpertTool;`)。
    *   在 `ToolRegistry::with_defaults()` 函数中，将你的工具添加进去：`registry.register(Arc::new(CatenaryExpertTool));`。

4.  **编译**: 运行 `cargo build` 编译项目，使新工具生效。

---

### 第三阶段：技能编排 (Skill Orchestration in Rhai)

技能是专家的“大脑”，它定义了如何使用工具来完成一个复杂的任务。

1.  **创建技能目录**: 在你的领域专家目录下 (`domain_experts/catenary/`) 创建 `skills/<your_skill_name>` 目录。
    ```bash
    mkdir -p domain_experts/catenary/skills/catenary_placement
    ```

2.  **编写技能描述 (`SKILL.md`)**: 在技能目录中，创建一个 `SKILL.md` 文件，用自然语言描述这个技能的目标、工作逻辑和使用的工具。

3.  **编写技能脚本 (`SKILL.rhai`)**: 这是技能的核心。
    *   创建一个 `.rhai` 文件，定义一个或多个函数来执行工作流。
    *   在函数内部，通过函数调用的方式使用你在第二阶段创建的工具。例如：`let result = catenary_expert(#{ subcommand: "get_max_span", ... });`。
    *   使用 `print()` 函数来输出日志，方便调试。
    *   实现 `SKILL.md` 中定义的决策逻辑（循环、条件判断等）。

---

### 第四阶段：测试与验证 (Testing & Verification)

最后一步是确保你的专家能按预期工作。

1.  **准备测试入口**: 在你的 `SKILL.rhai` 脚本末尾，添加一个测试“挽具”（harness）。这段代码会检查是否存在一个名为 `user_input` 的变量（这是测试命令注入的），如果存在，就执行它。
    ```rhai
    // In SKILL.rhai
    if type_of(user_input) == "string" && user_input != "" {
        eval(user_input); // Execute the command string passed from the test
    }
    ```

2.  **执行测试**: 使用 `skills test` 命令来运行你的技能。
    *   `<PATH>` 参数指向你的技能目录。
    *   `--input` 参数传入一个字符串，这个字符串就是你希望在脚本中被 `eval()` 执行的函数调用。

    ```bash
    # 在项目根目录运行
    ./target/debug/blockcell skills test domain_experts/catenary/skills/catenary_placement --input "run_placement(95.0, 110.0)"
    ```

3.  **调试**: 观察测试输出。如果出现编译错误，根据提示修改你的 `.rhai` 脚本。如果出现运行时错误，检查你的工具调用逻辑和参数是否正确。

通过以上四个阶段，你就成功地将一个领域的知识、工具和工作流封装到了 Blockcell 中，使其成为了一个真正的领域专家。
