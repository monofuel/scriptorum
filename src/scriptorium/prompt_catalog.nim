import
  std/[strformat, strutils]

const
  PromptDirectory = "prompts/"
  CodingAgentTemplate* = staticRead(PromptDirectory & "coding_agent.md")
  ArchitectAreasTemplate* = staticRead(PromptDirectory & "architect_areas.md")
  ManagerTicketsTemplate* = staticRead(PromptDirectory & "manager_tickets.md")
  PlanScopeTemplate* = staticRead(PromptDirectory & "plan_scope.md")
  ArchitectPlanOneShotTemplate* = staticRead(PromptDirectory & "architect_plan_oneshot.md")
  ArchitectPlanInteractiveTemplate* = staticRead(PromptDirectory & "architect_plan_interactive.md")
  CodexRetryContinuationTemplate* = staticRead(PromptDirectory & "codex_retry_continuation.md")
  CodexRetryDefaultContinuationText* = staticRead(PromptDirectory & "codex_retry_default_continuation.md")

type
  PromptBinding* = tuple[name: string, value: string]

proc markerForPlaceholder(name: string): string =
  ## Return one placeholder marker for the provided placeholder name.
  let clean = name.strip()
  if clean.len == 0:
    raise newException(ValueError, "placeholder name cannot be empty")
  result = "{{" & clean & "}}"

proc unresolvedPlaceholder(value: string): string =
  ## Return one unresolved placeholder marker when present.
  let startIndex = value.find("{{")
  if startIndex < 0:
    return ""

  let endIndex = value.find("}}", startIndex + 2)
  if endIndex < 0:
    result = value[startIndex..^1]
  else:
    result = value[startIndex..(endIndex + 1)]

proc renderPromptTemplate*(templateText: string, bindings: openArray[PromptBinding]): string =
  ## Render one prompt template with required placeholder bindings.
  if templateText.strip().len == 0:
    raise newException(ValueError, "prompt template cannot be empty")

  result = templateText
  for binding in bindings:
    let marker = markerForPlaceholder(binding.name)
    if result.find(marker) < 0:
      raise newException(ValueError, &"prompt template is missing placeholder: {marker}")
    result = result.replace(marker, binding.value)

  let unresolved = unresolvedPlaceholder(result)
  if unresolved.len > 0:
    raise newException(ValueError, &"prompt template has unresolved placeholder: {unresolved}")
