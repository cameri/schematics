# Module: <module-name>

Full contract for this module. Referenced from SCHEMATIC.md's Modules section.
Everything another module needs from this one appears here — no implicit
coupling.

## Purpose

One paragraph: what this module is responsible for, and what it is explicitly
NOT responsible for.

## Inputs

What it consumes, with exact formats/schemas (or references to the owning
section in SCHEMATIC.md). Include error inputs it must tolerate.

## Outputs

What it produces, with exact formats/schemas. Include side effects (files
written, state changed, messages sent) and their idempotency behavior.

## Dependencies

Ids from the schematic's Dependency and Parameter tables — nothing else. If
this module needs something from a sibling module, that need is declared here
AND in the sibling's Outputs.

## Failure Behavior

For each dependency and input class: what happens when it is missing, wrong,
or unreachable — hard fail (with the exact error the host sees) or degrade
(how). No silent fallbacks.

## Idempotency Notes

Which operations are safe to re-run, which are not, and how completion is
detected so a re-run can skip completed work.

## Removal Notes

What this module adds to the host (files, state, registrations) and what
removing it entails — feeds SCHEMATIC.md's Removal section.
