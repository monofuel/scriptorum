## Unit tests for centralized prompt template rendering.

import
  std/[strutils, unittest],
  scriptorium/prompt_catalog

suite "prompt catalog":
  test "renderPromptTemplate replaces all bound placeholders":
    let rendered = renderPromptTemplate(
      "alpha {{ONE}} beta {{TWO}} gamma\n",
      [
        (name: "ONE", value: "first"),
        (name: "TWO", value: "second"),
      ],
    )

    check rendered == "alpha first beta second gamma\n"

  test "renderPromptTemplate fails when requested placeholder is absent":
    expect ValueError:
      discard renderPromptTemplate(
        "alpha {{ONE}} beta\n",
        [
          (name: "TWO", value: "second"),
        ],
      )

  test "renderPromptTemplate fails when template keeps unresolved placeholders":
    expect ValueError:
      discard renderPromptTemplate(
        "alpha {{ONE}} beta {{TWO}}\n",
        [
          (name: "ONE", value: "first"),
        ],
      )

  test "template constants include expected placeholder markers":
    check CodingAgentTemplate.contains("{{TICKET_PATH}}")
    check ArchitectAreasTemplate.contains("{{CURRENT_SPEC}}")
    check ManagerTicketsTemplate.contains("{{AREA_CONTENT}}")
    check PlanScopeTemplate.contains("{{REPO_PATH}}")
    check ArchitectPlanOneShotTemplate.contains("{{USER_REQUEST}}")
    check ArchitectPlanInteractiveTemplate.contains("{{USER_MESSAGE}}")
    check CodexRetryContinuationTemplate.contains("{{TIMEOUT_KIND}}")
    check CodexRetryDefaultContinuationText.contains("Continue from the previous attempt")
