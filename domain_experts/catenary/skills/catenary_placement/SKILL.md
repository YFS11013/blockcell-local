# Skill: Catenary Pole Placement

This skill orchestrates the automated placement of catenary poles along a railway track based on established engineering rules.

## Objective

To generate a valid and optimized layout of catenary poles between a given start and end kilometer mark.

## Core Logic

The skill operates in a loop, starting from the `start_km`. In each iteration, it determines the position of the *next* pole based on a series of rules, executed in order of priority:

1.  **Check for Structural Constraints**: It first calls the `catenary_expert` tool with the `get_structure_at` subcommand to identify the type of structure at the current location.
2.  **Apply Snapping Rules**:
    *   If on a "BoxGirder" bridge, it will calculate the mandatory snapping points based on the B-01 rule (8.3m offset).
    *   (Future) If on a "TGirder", it will snap to pier centers.
    *   (Future) If near a "Tunnel", it will align with pre-embedded channels.
3.  **Apply Default Span**: If no structural constraints apply (e.g., on "Subgrade"), it will calculate the next pole's position using a standard span. This is determined by calling `catenary_expert` with `get_max_span_by_radius`.
4.  **Validation**: Each proposed pole position is validated against P0 rules (e.g., ensuring the span to the previous pole does not exceed the maximum allowed).
5.  **Iteration**: The current position is advanced to the newly placed pole's location, and the loop continues until the `end_km` is reached.

## Tools Used

*   `catenary_expert`: The primary tool for all domain-specific calculations.
*   `print`: For logging output.
