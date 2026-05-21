#!/usr/bin/env python3
from __future__ import annotations

import configparser
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CONFIG_PATH = ROOT / "runtime" / "generated" / "usersettings.json"

ENGINE_FIELDS = {
    "mining_output_multiplier": ("HarvestingSettings", "miningOutputMultiplier", "1.0"),
    "vehicle_mining_output_multiplier": ("HarvestingSettings", "vehicleMiningOutputMultiplier", "1.0"),
    "pvp_resource_multiplier": ("HarvestingSettings", "securityZonesPvpResourceMultiplier", "2.5"),
    "vehicle_durability_damage_multiplier": ("CombatSettings", "vehicleDurabilityDamageMultiplier", "1.0"),
    "sandstorm_enabled": ("SurvivalSettings", "sandstormEnabled", "1"),
    "sandstorm_treasure_enabled": ("SurvivalSettings", "sandStormTreasureEnabled", "1"),
    "sandworm_enabled": ("SurvivalSettings", "sandwormEnabled", "1"),
    "sandworm_collision_interaction": ("SurvivalSettings", "vehicleSandwormCollisionInteraction", "false"),
    "sandworm_danger_zones_enabled": ("SurvivalSettings", "sandwormDangerZonesEnabled", "true"),
    "sandworm_invulnerability_on_exit": ("SurvivalSettings", "vehicleSandwormInvulnerabilitySecondsOnExit", "900.0"),
    "sandworm_invulnerability_on_restart": ("SurvivalSettings", "vehicleSandwormInvulnerabilitySecondsOnServerRestart", "7200.0"),
}

MAP_FIELDS = {
    "force_enable_pvp_all_partitions": ("CombatSettings", "shouldForceEnablePvpOnAllPartitions", "False"),
    "security_zones_enabled": ("CombatSettings", "areSecurityZonesEnabled", "True"),
    "item_deterioration_rate": ("CombatSettings", "itemDeteriorationUpdateRate", "1.0"),
    "coriolis_auto_spawn_enabled": ("SurvivalSettings", "sandStormCoriolisAutoSpawnEnabled", "True"),
    "max_landclaim_segments": ("PersistenceSettings", "maxLandclaimSegments", ""),
    "building_blueprint_max_extensions": ("PersistenceSettings", "buildingBlueprintMaxExtensions", "4"),
    "base_backup_max_extensions": ("PersistenceSettings", "baseBackupMaxExtensions", "8"),
    "building_restriction_limits_enabled": ("PersistenceSettings", "buildingRestrictionLimitsEnabled", ""),
}


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        return {"engine": {}, "maps": {}, "partitions": {}}
    config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    config.setdefault("engine", {})
    config.setdefault("maps", {})
    config.setdefault("partitions", {})
    return config


def save_config(config: dict) -> None:
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def canonical_map(value: str) -> str:
    target = value.strip().lower()
    aliases = {
        "survival": "Survival_1",
        "survival-1": "Survival_1",
        "survival_1": "Survival_1",
        "overmap": "Overmap",
    }
    if target in aliases:
        return aliases[target]
    return value


def merged_engine_values(config: dict) -> dict[str, str]:
    values = {key: spec[2] for key, spec in ENGINE_FIELDS.items()}
    values.update(config.get("engine", {}))
    return values


def merged_map_values(config: dict, map_name: str) -> dict[str, str]:
    values = {key: spec[2] for key, spec in MAP_FIELDS.items()}
    values.update(config.get("maps", {}).get(map_name, {}))
    return values


def merged_partition_values(config: dict, map_name: str, partition_id: str) -> dict[str, str]:
    values = merged_map_values(config, map_name)
    partition_entry = config.get("partitions", {}).get(str(partition_id), {})
    values.update(partition_entry.get("usergame", {}))
    return values


def print_rows(rows: dict[str, str], order: dict[str, tuple[str, str, str]]) -> int:
    for key in order:
        print(f"{key}\t{rows.get(key, '')}")
    return 0


def set_field(scope: str, name: str | None, field_id: str, value: str) -> int:
    config = load_config()
    if scope == "engine":
        if field_id not in ENGINE_FIELDS:
            raise SystemExit(f"Unknown engine field: {field_id}")
        config.setdefault("engine", {})[field_id] = value
    else:
        if field_id not in MAP_FIELDS:
            raise SystemExit(f"Unknown map field: {field_id}")
        map_name = canonical_map(name or "")
        config.setdefault("maps", {}).setdefault(map_name, {})[field_id] = value
    save_config(config)
    return 0


def set_partition_field(map_name: str, partition_id: str, field_id: str, value: str) -> int:
    if field_id not in MAP_FIELDS:
        raise SystemExit(f"Unknown map field: {field_id}")
    config = load_config()
    entry = config.setdefault("partitions", {}).setdefault(str(partition_id), {})
    entry["map"] = canonical_map(map_name)
    entry.setdefault("usergame", {})[field_id] = value
    save_config(config)
    return 0


def reset_all() -> int:
    if CONFIG_PATH.exists():
        CONFIG_PATH.unlink()
    return 0


def write_ini(path: Path, values: dict[str, str], schema: dict[str, tuple[str, str, str]]) -> None:
    parser = configparser.ConfigParser(interpolation=None)
    parser.optionxform = str
    for field_id, (section, key, _) in schema.items():
        value = values.get(field_id, "")
        if value == "":
            continue
        if not parser.has_section(section):
            parser.add_section(section)
        parser.set(section, key, value)
    path.write_text("", encoding="utf-8")
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        parser.write(handle, space_around_delimiters=False)


def materialize(map_name: str, saved_dir: str, partition_id: str | None = None) -> int:
    config = load_config()
    target_map = canonical_map(map_name)
    user_settings_dir = Path(saved_dir) / "UserSettings"
    user_settings_dir.mkdir(parents=True, exist_ok=True)
    write_ini(user_settings_dir / "UserEngine.ini", merged_engine_values(config), ENGINE_FIELDS)
    if partition_id:
        values = merged_partition_values(config, target_map, str(partition_id))
    else:
        values = merged_map_values(config, target_map)
    write_ini(user_settings_dir / "UserGame.ini", values, MAP_FIELDS)
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        return 2

    command = argv[1]
    config = load_config()

    if command == "engine-values":
        return print_rows(merged_engine_values(config), ENGINE_FIELDS)
    if command == "map-values" and len(argv) == 3:
        return print_rows(merged_map_values(config, canonical_map(argv[2])), MAP_FIELDS)
    if command == "partition-values" and len(argv) == 4:
        return print_rows(merged_partition_values(config, canonical_map(argv[2]), argv[3]), MAP_FIELDS)
    if command == "engine-set" and len(argv) == 4:
        return set_field("engine", None, argv[2], argv[3])
    if command == "map-set" and len(argv) == 5:
        return set_field("map", argv[2], argv[3], argv[4])
    if command == "partition-set" and len(argv) == 6:
        return set_partition_field(argv[2], argv[3], argv[4], argv[5])
    if command == "reset-all":
        return reset_all()
    if command == "materialize" and len(argv) == 4:
        return materialize(argv[2], argv[3])
    if command == "materialize" and len(argv) == 5:
        return materialize(argv[2], argv[3], argv[4])

    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
