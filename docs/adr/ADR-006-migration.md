# ADR-006: External Migration Boundary

Status: Superseded

## Decision

TermPilot is maintained as a self-contained application and does not read,
import, dual-write, or build against another application's database or source
tree.

The earlier compatibility prototype and its cross-project fixture generator
were removed because they had no product entry point, no current Swift
implementation, and required a sibling source repository. TermPilot's supported
data boundary is its encrypted Vault under:

`~/Library/Application Support/TermPilot/`

Any future import feature must use a documented, versioned interchange format.
It must be implemented and tested entirely inside this repository, validate all
references in a staging database, encrypt secrets as Vault fields, and commit
atomically. Direct source imports and dependencies on another repository are
not permitted.
