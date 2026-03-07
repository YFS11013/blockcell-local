// Constants
const DEFAULT_RADIUS = 3500.0; // Default curve radius for subgrade sections.

fn run_placement(start_km, end_km) {
    print("Starting Catenary Placement...");
    print(`Layout from KM ${start_km} to KM ${end_km}`);
    print("----------------------------------------");

    let mut current_km = start_km;
    let mut pole_count = 0;

    print(`Placing first pole at ${current_km}`);
    pole_count += 1;

    while current_km < end_km {
        let last_pole_km = current_km;
        let mut next_pole_km = 0.0;
        let mut placement_reason = "";

        let structure_info_result = catenary_expert(#{ subcommand: "get_structure_at", km: current_km });

        if structure_info_result.is_ok() {
            let s = structure_info_result.unwrap();
            if s.structure_type == "BoxGirder" {
                let snap_point = s.km_start + 8.3;
                if snap_point > current_km {
                    let span = snap_point - last_pole_km;
                    let max_span_result = catenary_expert(#{ subcommand: "get_max_span_by_radius", radius: DEFAULT_RADIUS });
                    if max_span_result.is_ok() && span > max_span_result.unwrap().max_span {
                        placement_reason = "Default Span (Snap Exceeds Max)";
                        next_pole_km = last_pole_km + max_span_result.unwrap().max_span;
                    } else {
                        placement_reason = "BoxGirder Snap";
                        next_pole_km = snap_point;
                    }
                }
            }
        }
        
        if next_pole_km == 0.0 {
             let max_span_result = catenary_expert(#{ subcommand: "get_max_span_by_radius", radius: DEFAULT_RADIUS });
             if max_span_result.is_ok() {
                let max_span = max_span_result.unwrap().max_span;
                next_pole_km = last_pole_km + max_span;
                placement_reason = "Default Span";
             } else {
                print("Error: Could not determine max span. Halting.");
                break;
             }
        }

        if next_pole_km > end_km {
            next_pole_km = end_km;
            placement_reason = "Final Pole at End";
        }

        current_km = next_pole_km;
        pole_count += 1;
        let span = current_km - last_pole_km;

        let log_msg = `[Pole #${pole_count}] Placed at KM ${current_km.to_string().pad_start(7, " ")} | Span: ${span.to_string().pad_end(5, " ")} | Reason: ${placement_reason}`;
        print(log_msg);

        if pole_count > 1000 {
            print("Error: Exceeded 1000 poles, safety break.");
            break;
        }
    }

    print("----------------------------------------");
    print(`Placement finished. Total poles: ${pole_count}`);
    return "Execution Finished.";
}

// Test harness
if type_of(user_input) == "string" && user_input != "" {
    print(`Executing test input: ${user_input}`);
    eval(user_input);
}
