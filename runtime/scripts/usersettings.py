#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CONFIG_PATH = ROOT / "runtime" / "generated" / "usersettings.json"
SIETCH_CONFIG_PATH = ROOT / "runtime" / "generated" / "sietch-config.json"

ENGINE_FIELDS = {
    "port": ("URL", "Port", "7777"),
    "igw_port": ("URL", "IGWPort", "7888"),
    "server_display_name": ("ConsoleVariables", "Bgd.ServerDisplayName", None),
    "server_login_password": ("ConsoleVariables", "Bgd.ServerLoginPassword", None),
    "mining_output_multiplier": ("ConsoleVariables", "Dune.GlobalMiningOutputMultiplier", "1.0"),
    "vehicle_mining_output_multiplier": ("ConsoleVariables", "Dune.GlobalVehicleMiningOutputMultiplier", "1.0"),
    "pvp_resource_multiplier": ("ConsoleVariables", "SecurityZones.PvpResourceMultiplier", "2.5"),
    "vehicle_durability_damage_multiplier": ("ConsoleVariables", "dw.VehicleDurabilityDamageMultiplier", "1.0"),
    "sandstorm_enabled": ("ConsoleVariables", "Sandstorm.Enabled", "1"),
    "sandstorm_treasure_enabled": ("ConsoleVariables", "Sandstorm.Treasure.Enabled", "1"),
    "sandworm_enabled": ("ConsoleVariables", "sandworm.dune.Enabled", "1"),
    "sandworm_collision_interaction": ("ConsoleVariables", "Vehicle.SandwormCollisionInteraction", "false"),
    "sandworm_danger_zones_enabled": ("ConsoleVariables", "Sandworm.SandwormDangerZonesEnabled", "true"),
    "sandworm_invulnerability_on_exit": ("ConsoleVariables", "Vehicle.SandwormInvulnerabilitySecondsOnExit", "900.0"),
    "sandworm_invulnerability_on_restart": ("ConsoleVariables", "Vehicle.SandwormInvulnerabilitySecondsOnServerRestart", "7200.0"),
}

MAP_FIELDS = {
    "force_pvp_all_partitions": ("/Script/DuneSandbox.PvpPveSettings", "m_bShouldForceEnablePvpOnAllPartitions", "False"),
    "security_zones_enabled": ("/Script/DuneSandbox.SecurityZonesSubsystem", "m_bAreSecurityZonesEnabled", "True"),
    "item_deterioration_rate": ("/DeteriorationSystem.ItemDeteriorationConstants", "UpdateRateInSeconds", "1.0"),
    "coriolis_auto_spawn_enabled": ("/Script/DuneSandbox.SandStormConfig", "m_bCoriolisAutoSpawnEnabled", "True"),
    "storm_cycle_duration": ("/Script/DuneSandbox.SandStormConfig", "m_StormCycleDuration", "7200"),
    "storm_duration": ("/Script/DuneSandbox.SandStormConfig", "m_StormDuration", "600"),
    "storm_warning_duration": ("/Script/DuneSandbox.SandStormConfig", "m_StormWarningDuration", "120"),
    "storm_cycle_wait": ("/Script/DuneSandbox.SandStormConfig", "m_StormCycleWait", "300"),
    "max_landclaim_segments": ("/Script/DuneSandbox.BuildingSettings", "m_MaxNumLandclaimSegments", "6"),
    "building_blueprint_max_extensions": ("/Script/DuneSandbox.BuildingSettings", "m_BuildingBlueprintMaxExtensions", "4"),
    "base_backup_max_extensions": ("/Script/DuneSandbox.BuildingSettings", "m_BaseBackupMaxExtensions", "8"),
    "building_restriction_limits_enabled": ("/Script/DuneSandbox.BuildingSettings", "m_bBuildingRestrictionLimitsEnabled", "True"),
    "global_xp_multiplier": ("/Script/DuneSandbox.DuneGameMode", "m_GlobalXPMultiplier", "1.0"),
    "global_fame_multiplier": ("/Script/DuneSandbox.DuneGameMode", "m_GlobalFameMultiplier", "1.0"),
    "global_progression_speed_multiplier": ("/Script/DuneSandbox.DuneGameMode", "m_GlobalProgressionSpeedMultiplier", "1.0"),
    "guild_creation_cost": ("/Script/DuneSandbox.DuneGameMode", "m_GuildCreationCost", "1000"),
    "sell_order_price_percentage_fee": ("/Script/DuneSandbox.DuneGameMode", "SellOrderPricePercentageFee", "2.0"),
    "spice_tax_amount": ("/Script/DuneSandbox.DuneGameMode", "SpiceTaxAmount", "0.1"),
    "spice_tax_interval": ("/Script/DuneSandbox.DuneGameMode", "SpiceTaxInterval", "3600"),
    "global_harvest_amount_multiplier": ("/Script/DuneSandbox.DuneGameMode", "m_GlobalHarvestAmountMultiplier", "1.0"),
    "global_harvest_health_multiplier": ("/Script/DuneSandbox.DuneGameMode", "m_GlobalHarvestHealthMultiplier", "1.0"),
    "cutteray_hem_multiplier_per_node_tier_table": ("/Script/DuneSandbox.DuneGameMode", "CutterayHemMultiplierPerNodeTierTable", "1.0"),
    "minimum_augmentable_item_quality": ("/Script/DuneSandbox.DuneGameMode", "m_MinimumAugmentableItemQuality", "0"),
    "item_durability_loss_multiplier": ("/Script/DuneSandbox.DuneGameMode", "m_ItemDurabilityLossMultiplier", "1.0"),
    "legacy_pvp_enabled": ("/Script/DuneSandbox.DuneGameMode", "bPvPEnabled", "False"),
    "server_pve": ("/Script/DuneSandbox.DuneGameMode", "bServerPVE", "True"),
    "water_consumption_rate": ("/Script/DuneSandbox.DuneGameMode", "m_WaterConsumptionRate", "1.0"),
    "water_consumption_in_storm_multiplier": ("/Script/DuneSandbox.DuneGameMode", "m_WaterConsumptionInStormMultiplier", "4.0"),
    "global_damage_to_npcs_multiplier": ("/Script/DuneSandbox.DuneGameMode", "m_GlobalDamageToNpcsMultiplier", "1.0"),
    "global_damage_to_players_multiplier": ("/Script/DuneSandbox.DuneGameMode", "m_GlobalDamageToPlayersMultiplier", "1.0"),
    "global_health_multiplier": ("/Script/DuneSandbox.DuneGameMode", "m_GlobalHealthMultiplier", "1.0"),
    "global_building_damage_multiplier": ("/Script/DuneSandbox.DuneGameMode", "m_GlobalBuildingDamageMultiplier", "1.0"),
    "building_decay_rate_multiplier": ("/Script/DuneSandbox.DuneGameMode", "m_BuildingDecayRateMultiplier", "1.0"),
    "enable_building_stability": ("/Script/DuneSandbox.DuneGameMode", "bEnableBuildingStability", "True"),
    "inventory_weight_multiplier": ("/Script/DuneSandbox.DuneGameMode", "m_InventoryWeightMultiplier", "1.0"),
    "player_starting_water": ("/Script/DuneSandbox.DuneGameMode", "m_PlayerStartingWater", "100.0"),
    "default_reconnect_grace_period_seconds": ("/Script/DuneSandbox.DuneGameMode", "m_DefaultReconnectGracePeriodSeconds", "300"),
    "cycle_duration_in_days": ("/Script/DuneSandbox.DuneGameMode", "m_CycleDurationInDays", "7"),
    "db_wipe_enabled": ("/Script/DuneSandbox.DuneGameMode", "m_bIsDbWipeEnabled", "True"),
    "max_guild_members_allowed": ("/Script/DuneSandbox.DuneGameMode", "m_MaxGuildMembersAllowed", "32"),
    "max_guilds_allowed": ("/Script/DuneSandbox.DuneGameMode", "m_MaxGuildsAllowed", "3"),
    "max_permissions_per_actor": ("/Script/DuneSandbox.DuneGameMode", "m_MaxPermissionsPerActor", "20"),
    "vehicle_quicksand_damage": ("/Script/DuneSandbox.DuneGameMode", "m_VehicleQuicksandDamage", "10.0"),
    "player_inventory_starting_size": ("/Script/DuneSandbox.InventorySystemSettings", "PlayerInventoryStartingSize", "40"),
    "player_inventory_starting_volume_capacity": ("/Script/DuneSandbox.InventorySystemSettings", "PlayerInventoryStartingVolumeCapacity", "225.0"),
    "sandworm_system": ("/Script/DuneSandbox.SandwormSettings", "m_EnableSandwormSystem", "UseAllowList"),
    "worm_detection_distance": ("/Script/DuneSandbox.SandwormSettings", "WormDetectionDistance", "5000.0"),
    "min_worm_spawn_interval": ("/Script/DuneSandbox.SandwormSettings", "m_MinWormSpawnInternal", "300.0"),
    "min_distance_between_sandworms": ("/Script/DuneSandbox.SandwormSettings", "m_MinDistanceBetweenSandworms", "3000.0"),
    "sandworm_quicksand_speed_modifier": ("/Script/DuneSandbox.SandwormSettings", "m_SandwormQuicksandSpeedModifier", "0.5"),
    "patrol_ship_spawn_time": ("/Script/DuneSandbox.PatrolShipSettings", "m_TimeOfDayToSpawn", "18.0"),
    "patrol_ship_despawn_time": ("/Script/DuneSandbox.PatrolShipSettings", "m_TimeOfDayToDespawn", "6.0"),
}

PARTITION_FIELDS = {
    "partition_pvp_enabled": (None, None, "False"),
    "partition_pve_enabled": (None, None, "False"),
    **MAP_FIELDS,
}

PARTITION_ENGINE_FIELDS = {
    "server_display_name": ENGINE_FIELDS["server_display_name"],
    "server_login_password": ENGINE_FIELDS["server_login_password"],
}


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        return {"engine": {}, "maps": {}, "partitions": {}}
    try:
        config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"engine": {}, "maps": {}, "partitions": {}}
    config.setdefault("engine", {})
    config.setdefault("maps", {})
    config.setdefault("partitions", {})
    return config


def atomic_write_text(path: Path, content: str, mode: int = 0o664) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.parent / f".{path.name}.tmp.{os.getpid()}"
    tmp_path.write_text(content, encoding="utf-8")
    try:
        tmp_path.chmod(mode)
    except OSError:
        pass
    tmp_path.replace(path)
    try:
        path.chmod(mode)
    except OSError:
        pass


def save_config(config: dict) -> None:
    atomic_write_text(CONFIG_PATH, json.dumps(config, indent=2, sort_keys=True) + "\n")


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


def max_survival_dimensions() -> int:
    if SIETCH_CONFIG_PATH.exists():
        config = json.loads(SIETCH_CONFIG_PATH.read_text(encoding="utf-8"))
        value = config.get("maps", {}).get("Survival_1", {}).get("max_dimensions")
        try:
            parsed = int(value)
            if parsed > 0:
                return parsed
        except (TypeError, ValueError):
            pass
    return 4


def validate_port_ranges(config: dict, field_id: str, value: str) -> None:
    try:
        candidate = int(value)
    except ValueError as exc:
        raise SystemExit(f"{field_id} must be a positive integer.") from exc
    if candidate <= 0:
        raise SystemExit(f"{field_id} must be a positive integer.")

    engine = dict(config.get("engine", {}))
    engine[field_id] = str(candidate)
    client_start = int(engine.get("port") or ENGINE_FIELDS["port"][2])
    igw_start = int(engine.get("igw_port") or ENGINE_FIELDS["igw_port"][2])
    end_offset = max_survival_dimensions()
    client_end = client_start + end_offset
    igw_end = igw_start + end_offset
    if not (client_end < igw_start or igw_end < client_start):
        raise SystemExit(
            f"Configured Port range {client_start}-{client_end} intersects with IGWPort range {igw_start}-{igw_end}."
        )


def merged_engine_values(config: dict) -> dict[str, str]:
    values = {key: spec[2] for key, spec in ENGINE_FIELDS.items() if spec[2] is not None}
    values.update(config.get("engine", {}))
    return values


def merged_map_values(config: dict, map_name: str) -> dict[str, str]:
    values = {key: spec[2] for key, spec in MAP_FIELDS.items()}
    values.update(config.get("maps", {}).get(map_name, {}))
    return values


def merged_partition_values(config: dict, map_name: str, partition_id: str) -> dict[str, str]:
    values = {key: spec[2] for key, spec in PARTITION_FIELDS.items()}
    values.update(config.get("maps", {}).get(map_name, {}))
    partition_entry = config.get("partitions", {}).get(str(partition_id), {})
    values.update(partition_entry.get("usergame", {}))
    return values


def merged_partition_engine_values(config: dict, partition_id: str) -> dict[str, str]:
    values = merged_engine_values(config)
    partition_entry = config.get("partitions", {}).get(str(partition_id), {})
    values.update(partition_entry.get("userengine", {}))
    return values


def print_rows(rows: dict[str, str], order: dict[str, tuple[str | None, str | None, str]]) -> int:
    for key in order:
        print(f"{key}\t{rows.get(key, '')}")
    return 0


def set_field(scope: str, name: str | None, field_id: str, value: str) -> int:
    config = load_config()
    if scope == "engine":
        if field_id not in ENGINE_FIELDS:
            raise SystemExit(f"Unknown engine field: {field_id}")
        if field_id in {"port", "igw_port"}:
            validate_port_ranges(config, field_id, value)
        config.setdefault("engine", {})[field_id] = value
    else:
        if field_id not in MAP_FIELDS:
            raise SystemExit(f"Unknown map field: {field_id}")
        map_name = canonical_map(name or "")
        config.setdefault("maps", {}).setdefault(map_name, {})[field_id] = value
    save_config(config)
    return 0


def set_partition_field(map_name: str, partition_id: str, field_id: str, value: str) -> int:
    if field_id not in PARTITION_FIELDS:
        raise SystemExit(f"Unknown partition field: {field_id}")
    config = load_config()
    entry = config.setdefault("partitions", {}).setdefault(str(partition_id), {})
    entry["map"] = canonical_map(map_name)
    entry.setdefault("usergame", {})[field_id] = value
    save_config(config)
    return 0


def set_partition_engine_field(map_name: str, partition_id: str, field_id: str, value: str) -> int:
    if field_id not in PARTITION_ENGINE_FIELDS:
        raise SystemExit(f"Unknown partition engine field: {field_id}")
    config = load_config()
    entry = config.setdefault("partitions", {}).setdefault(str(partition_id), {})
    entry["map"] = canonical_map(map_name)
    entry.setdefault("userengine", {})[field_id] = value
    save_config(config)
    return 0


def reset_all() -> int:
    if CONFIG_PATH.exists():
        CONFIG_PATH.unlink()
    return 0


def quote_ini_string(value: str) -> str:
    raw = value.strip()
    if len(raw) >= 2 and raw[0] == '"' and raw[-1] == '"':
        return raw
    escaped = raw.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def truthy(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes", "on"}


def write_userengine_ini(path: Path, values: dict[str, str]) -> None:
    lines = [
        "; Settings in these config files will be applied to every server in the battlegroup",
        "; If you need to override different settings for different servers, use the battlegroup editor instead",
        "",
        "[URL]",
        "; The starting port that servers listen to for players. Each server",
        "; will use the next available port in a sequence (7777, 7778 etc.). The range should",
        "; not intersect with the IGWPort range bellow",
        f"Port={values.get('port', ENGINE_FIELDS['port'][2])}",
        "; The port that servers listen to for other servers. Each server",
        "; will use the next available port in a sequence (7888, 7889 etc.). The range should",
        "; not intersect with the Port range above",
        f"IGWPort={values.get('igw_port', ENGINE_FIELDS['igw_port'][2])}",
        "",
        "[ConsoleVariables]",
        "; Set the name of every Sietch in the battlegroup",
        "; If Sietches should have different names use the battlegroup editor instead",
        "; Special characters like ' and | are not allowed and double quotes should be used",
    ]

    display_name = values.get("server_display_name", "")
    if display_name:
        lines.append(f"Bgd.ServerDisplayName={quote_ini_string(display_name)}")
    else:
        lines.append(';Bgd.ServerDisplayName="My Arrakis, My Dune"')

    lines.extend([
        "",
        "; Set a password for every Sietch in the battlegroup",
        "; If Sietches should have different passwords use the battlegroup editor instead",
        "; Special characters like ' and | are not allowed and double quotes should be used",
    ])

    login_password = values.get("server_login_password", "")
    if login_password:
        lines.append(f"Bgd.ServerLoginPassword={quote_ini_string(login_password)}")
    else:
        lines.append(';Bgd.ServerLoginPassword="Sandworm"')

    lines.extend([
        "",
        "; Mining multipliers",
        f"Dune.GlobalMiningOutputMultiplier={values.get('mining_output_multiplier', ENGINE_FIELDS['mining_output_multiplier'][2])}",
        f"Dune.GlobalVehicleMiningOutputMultiplier={values.get('vehicle_mining_output_multiplier', ENGINE_FIELDS['vehicle_mining_output_multiplier'][2])}",
        f"SecurityZones.PvpResourceMultiplier={values.get('pvp_resource_multiplier', ENGINE_FIELDS['pvp_resource_multiplier'][2])}",
        "",
        "; Durability damage multiplier for vehicles | (0 to 10)  0=off",
        f"dw.VehicleDurabilityDamageMultiplier={values.get('vehicle_durability_damage_multiplier', ENGINE_FIELDS['vehicle_durability_damage_multiplier'][2])}",
        "",
        "; Sandstorm and sandstorm treasure spawning settings",
        f"Sandstorm.Enabled={values.get('sandstorm_enabled', ENGINE_FIELDS['sandstorm_enabled'][2])}",
        f"Sandstorm.Treasure.Enabled={values.get('sandstorm_treasure_enabled', ENGINE_FIELDS['sandstorm_treasure_enabled'][2])} ",
        "",
        "; Sandworm settings",
        f"sandworm.dune.Enabled={values.get('sandworm_enabled', ENGINE_FIELDS['sandworm_enabled'][2])}",
        "; Sandworm can push/damage vehicles",
        f"Vehicle.SandwormCollisionInteraction={values.get('sandworm_collision_interaction', ENGINE_FIELDS['sandworm_collision_interaction'][2])}",
        "; Enables dangerzones where the sandworm can attack",
        f"Sandworm.SandwormDangerZonesEnabled={values.get('sandworm_danger_zones_enabled', ENGINE_FIELDS['sandworm_danger_zones_enabled'][2])}",
        "; Seconds of invunerability from sandworm on specific situations",
        f"Vehicle.SandwormInvulnerabilitySecondsOnExit={values.get('sandworm_invulnerability_on_exit', ENGINE_FIELDS['sandworm_invulnerability_on_exit'][2])}",
        f"Vehicle.SandwormInvulnerabilitySecondsOnServerRestart={values.get('sandworm_invulnerability_on_restart', ENGINE_FIELDS['sandworm_invulnerability_on_restart'][2])}",
    ])
    atomic_write_text(path, "\n".join(lines) + "\n")


def write_usergame_ini(path: Path, values: dict[str, str], partition_id: str | None = None) -> None:
    def field(field_id: str) -> str:
        section, key, default = MAP_FIELDS[field_id]
        return f"{key}={values.get(field_id, default)}"

    lines = [
        "; Settings in these config files will be applied to every server in the battlegroup",
        "; If you need to override different settings for different servers, use the battlegroup editor instead",
        "; Advanced community-documented fields below are emitted for Docker Saved/UserSettings use.",
        "",
        "[/Script/DuneSandbox.PvpPveSettings]",
        "; Enable PVP for all partitions",
        field("force_pvp_all_partitions"),
        "; Enable PVP for specific partitions. Example:",
    ]
    if partition_id:
        if truthy(values.get("partition_pvp_enabled", "False")):
            lines.append(f"+m_PvpEnabledPartitions={partition_id}")
        else:
            lines.append(";+m_PvpEnabledPartitions=1")
            lines.append(";+m_PvpEnabledPartitions=2")
    else:
        lines.append(";+m_PvpEnabledPartitions=1")
        lines.append(";+m_PvpEnabledPartitions=2")

    lines.append("; Explicitly enable PVE for specific partitions. Example:")
    if partition_id and truthy(values.get("partition_pve_enabled", "False")):
        lines.append(f"+m_PveEnabledPartitions={partition_id}")
    else:
        lines.append(";+m_PveEnabledPartitions=1")

    lines.extend([
        "",
        "[/Script/DuneSandbox.SecurityZonesSubsystem]",
        "; Disabling security zones across the board allows for PVP and ability usage everywhere",
        field("security_zones_enabled"),
        "",
        "[/DeteriorationSystem.ItemDeteriorationConstants]",
        "; Deterioration rate for items | (0 to 10)  0=off",
        field("item_deterioration_rate"),
        "",
        "[/Script/DuneSandbox.SandStormConfig]",
        "; Enable Coriolis storm",
        field("coriolis_auto_spawn_enabled"),
        "; Advanced storm timing settings from community documentation",
        field("storm_cycle_duration"),
        field("storm_duration"),
        field("storm_warning_duration"),
        field("storm_cycle_wait"),
        "",
        "[/Script/DuneSandbox.BuildingSettings]",
        "; Max number of landclaims. !Needs to also be applied to each client!",
        field("max_landclaim_segments"),
        "; Number of times a landclaim can be expanded",
        field("building_blueprint_max_extensions"),
        field("base_backup_max_extensions"),
        "; Enable building restriction limits !Needs to also be applied to each client!",
        field("building_restriction_limits_enabled"),
        "",
        "[/Script/DuneSandbox.DuneGameMode]",
        "; Advanced progression and economy settings from community documentation",
        field("global_xp_multiplier"),
        field("global_fame_multiplier"),
        field("global_progression_speed_multiplier"),
        field("guild_creation_cost"),
        field("sell_order_price_percentage_fee"),
        field("spice_tax_amount"),
        field("spice_tax_interval"),
        "",
        "; Advanced harvesting and crafting settings from community documentation",
        field("global_harvest_amount_multiplier"),
        field("global_harvest_health_multiplier"),
        field("cutteray_hem_multiplier_per_node_tier_table"),
        field("minimum_augmentable_item_quality"),
        field("item_durability_loss_multiplier"),
        "",
        "; Advanced survival and combat settings from community documentation",
        field("legacy_pvp_enabled"),
        field("server_pve"),
        field("water_consumption_rate"),
        field("water_consumption_in_storm_multiplier"),
        field("global_damage_to_npcs_multiplier"),
        field("global_damage_to_players_multiplier"),
        field("global_health_multiplier"),
        field("global_building_damage_multiplier"),
        field("building_decay_rate_multiplier"),
        field("enable_building_stability"),
        field("inventory_weight_multiplier"),
        field("player_starting_water"),
        field("default_reconnect_grace_period_seconds"),
        "",
        "; Advanced world reset, clan, permission, and vehicle settings from community documentation",
        field("cycle_duration_in_days"),
        field("db_wipe_enabled"),
        field("max_guild_members_allowed"),
        field("max_guilds_allowed"),
        field("max_permissions_per_actor"),
        field("vehicle_quicksand_damage"),
        "",
        "[/Script/DuneSandbox.InventorySystemSettings]",
        "; Advanced inventory settings from community documentation",
        field("player_inventory_starting_size"),
        field("player_inventory_starting_volume_capacity"),
        "",
        "[/Script/DuneSandbox.SandwormSettings]",
        "; Advanced sandworm settings from community documentation",
        field("sandworm_system"),
        field("worm_detection_distance"),
        field("min_worm_spawn_interval"),
        field("min_distance_between_sandworms"),
        field("sandworm_quicksand_speed_modifier"),
        "",
        "[/Script/DuneSandbox.PatrolShipSettings]",
        "; Advanced patrol ship settings from community documentation",
        field("patrol_ship_spawn_time"),
        field("patrol_ship_despawn_time"),
    ])
    atomic_write_text(path, "\n".join(lines) + "\n")


def safe_runtime_dir_name(map_name: str, partition_id: str) -> str:
    raw = f"{map_name}-{partition_id}".lower()
    chars: list[str] = []
    previous_dash = False
    for char in raw:
        if char.isalnum():
            chars.append(char)
            previous_dash = False
        else:
            if not previous_dash:
                chars.append("-")
                previous_dash = True
    return "".join(chars).strip("-")


def materialize_current_runtime_files() -> int:
    config = load_config()
    game_root = ROOT / "runtime" / "game"
    partition_catalog_path = SIETCH_CONFIG_PATH.parent / "partition-catalog.json"
    if not game_root.exists():
        return 0

    targets: list[tuple[str, Path, str | None]] = []

    overmap_dir = game_root / "overmap" / "Saved"
    if overmap_dir.exists():
        targets.append(("Overmap", overmap_dir, "2"))

    survival_dir = game_root / "survival-1" / "Saved"
    if survival_dir.exists():
        targets.append(("Survival_1", survival_dir, "1"))

    catalog_rows = []
    if partition_catalog_path.exists():
        try:
            catalog_rows = json.loads(partition_catalog_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            catalog_rows = []

    seen_paths = {path.resolve() for _, path, _ in targets if path.exists()}
    for row in catalog_rows:
        map_name = str(row.get("map", "")).strip()
        partition_id = str(row.get("id", "")).strip()
        if not map_name or not partition_id:
            continue
        saved_dir = game_root / safe_runtime_dir_name(map_name, partition_id) / "Saved"
        if not saved_dir.exists():
            continue
        resolved = saved_dir.resolve()
        if resolved in seen_paths:
            continue
        targets.append((canonical_map(map_name), saved_dir, partition_id))
        seen_paths.add(resolved)

    for map_name, saved_dir, partition_id in targets:
        user_settings_dir = saved_dir / "UserSettings"
        user_settings_dir.mkdir(parents=True, exist_ok=True)
        if partition_id:
            engine_values = merged_partition_engine_values(config, str(partition_id))
            values = merged_partition_values(config, canonical_map(map_name), str(partition_id))
        else:
            engine_values = merged_engine_values(config)
            values = merged_map_values(config, canonical_map(map_name))
        write_userengine_ini(user_settings_dir / "UserEngine.ini", engine_values)
        write_usergame_ini(user_settings_dir / "UserGame.ini", values, partition_id)
    return 0


def materialize(map_name: str, saved_dir: str, partition_id: str | None = None) -> int:
    config = load_config()
    target_map = canonical_map(map_name)
    user_settings_dir = Path(saved_dir) / "UserSettings"
    user_settings_dir.mkdir(parents=True, exist_ok=True)
    if partition_id:
        engine_values = merged_partition_engine_values(config, str(partition_id))
        values = merged_partition_values(config, target_map, str(partition_id))
    else:
        engine_values = merged_engine_values(config)
        values = merged_map_values(config, target_map)
    write_userengine_ini(user_settings_dir / "UserEngine.ini", engine_values)
    write_usergame_ini(user_settings_dir / "UserGame.ini", values, str(partition_id) if partition_id else None)
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
        return print_rows(merged_partition_values(config, canonical_map(argv[2]), argv[3]), PARTITION_FIELDS)
    if command == "partition-engine-values" and len(argv) == 4:
        return print_rows(merged_partition_engine_values(config, argv[3]), PARTITION_ENGINE_FIELDS)
    if command == "engine-set" and len(argv) == 4:
        return set_field("engine", None, argv[2], argv[3])
    if command == "map-set" and len(argv) == 5:
        return set_field("map", argv[2], argv[3], argv[4])
    if command == "partition-set" and len(argv) == 6:
        return set_partition_field(argv[2], argv[3], argv[4], argv[5])
    if command == "partition-engine-set" and len(argv) == 6:
        return set_partition_engine_field(argv[2], argv[3], argv[4], argv[5])
    if command == "reset-all":
        return reset_all()
    if command == "materialize-current":
        return materialize_current_runtime_files()
    if command == "materialize" and len(argv) == 4:
        return materialize(argv[2], argv[3])
    if command == "materialize" and len(argv) == 5:
        return materialize(argv[2], argv[3], argv[4])

    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
