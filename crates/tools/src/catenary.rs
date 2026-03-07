//! Catenary-specific tools for expert agent.
//！ 接触网专家智能体专用工具集

use async_trait::async_trait;
use serde_json::{json, Value};
use blockcell_core::{Error, Result};
use crate::{Tool, ToolContext, ToolSchema};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StructureInfo {
    pub name: String,
    pub km_start: f64,
    pub km_end: f64,
    pub structure_type: String, // "BoxGirder", "TGirder", "Tunnel", "Subgrade"
}

pub struct CatenaryExpertTool;

#[async_trait]
impl Tool for CatenaryExpertTool {
    fn schema(&self) -> ToolSchema {
        ToolSchema {
            name: "catenary_expert",
            description: "A tool for catenary design calculations, following standard operating procedures.",
            parameters: json!({
                "type": "object",
                "properties": {
                    "subcommand": {
                        "type": "string",
                        "description": "The calculation to perform.",
                        "enum": ["get_max_span_by_radius", "get_structure_at"]
                    },
                    "radius": {
                        "type": "number",
                        "description": "The curve radius in meters, required for 'get_max_span_by_radius'."
                    },
                    "km": {
                        "type": "number",
                        "description": "The kilometer mark, required for 'get_structure_at'."
                    }
                },
                "required": ["subcommand"]
            })
        }
    }

    fn validate(&self, params: &Value) -> Result<()> {
        let subcommand = params["subcommand"].as_str().ok_or_else(|| Error::Tool("Missing subcommand".to_string()))?;
        match subcommand {
            "get_max_span_by_radius" => {
                if !params["radius"].is_number() {
                    return Err(Error::Tool("Missing 'radius' parameter for subcommand 'get_max_span_by_radius'".to_string()));
                }
            }
            "get_structure_at" => {
                if !params["km"].is_number() {
                    return Err(Error::Tool("Missing 'km' parameter for subcommand 'get_structure_at'".to_string()));
                }
            }
            _ => return Err(Error::Tool(format!("Invalid subcommand: {}", subcommand)))
        }
        Ok(())
    }

    async fn execute(&self, _ctx: ToolContext, params: Value) -> Result<Value> {
        let subcommand = params["subcommand"].as_str().unwrap(); // Already validated

        match subcommand {
            "get_max_span_by_radius" => {
                let radius = params["radius"].as_f64().unwrap();
                let max_span = self.get_max_span_by_radius(radius);
                Ok(json!({ "max_span": max_span }))
            }
            "get_structure_at" => {
                let km = params["km"].as_f64().unwrap();
                let structure_info = self.get_structure_at(km);
                Ok(serde_json::to_value(structure_info)?)
            }
            _ => unreachable!(),
        }
    }
}

impl CatenaryExpertTool {
    fn get_max_span_by_radius(&self, radius: f64) -> f64 {
        if radius < 800.0 {
            40.0
        } else if radius < 1200.0 {
            45.0
        } else if radius < 3000.0 {
            50.0
        } else {
            55.0
        }
    }

    fn get_structure_at(&self, km: f64) -> StructureInfo {
        // Placeholder logic
        if km > 100.0 && km < 200.0 {
            StructureInfo {
                name: "Bridge_01".to_string(),
                km_start: 100.0,
                km_end: 200.0,
                structure_type: "BoxGirder".to_string(),
            }
        } else {
            StructureInfo {
                name: "Subgrade_01".to_string(),
                km_start: 0.0,
                km_end: 100.0,
                structure_type: "Subgrade".to_string(),
            }
        }
    }
}

use serde::{Deserialize, Serialize};
