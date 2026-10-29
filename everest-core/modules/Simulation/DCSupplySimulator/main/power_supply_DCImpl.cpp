// SPDX-License-Identifier: Apache-2.0
// Copyright chargebyte GmbH
// Copyright Pionix GmbH and Contributors to EVerest

#include <chrono>
#include <cstdlib>
#include <fstream>
#include <mutex>
#include <sstream>

#include "power_supply_DCImpl.hpp"

namespace module {
namespace main {

// Load a Zenodo-derived replay profile (CSV: t_s,target_voltage_V,target_current_A,soc_pct)
// from EV_REPLAY_PROFILE. EV_REPLAY_DURATION_S compresses the whole profile into that many
// seconds (0 = real time). Same getenv pattern as the A1 attack patch; no config changes.
void power_supply_DCImpl::replay_init() {
    replay_inited = true;
    const char* path = std::getenv("EV_REPLAY_PROFILE");
    if (path == nullptr || path[0] == '\0') {
        return;
    }
    std::ifstream f(path);
    if (!f) {
        EVLOG_warning << "[REPLAY/supply] cannot open EV_REPLAY_PROFILE=" << path;
        return;
    }
    std::string line;
    std::getline(f, line); // header
    while (std::getline(f, line)) {
        if (line.empty()) {
            continue;
        }
        std::stringstream ss(line);
        std::string cell;
        std::array<double, 4> row{0, 0, 0, 0};
        int j = 0;
        while (std::getline(ss, cell, ',') && j < 4) {
            try {
                row[j] = std::stod(cell);
            } catch (...) {
                row[j] = 0.0;
            }
            j++;
        }
        if (j >= 4) {
            replay_rows.push_back(row);
        }
    }
    const char* dur = std::getenv("EV_REPLAY_DURATION_S");
    replay_duration_s = (dur != nullptr && dur[0] != '\0') ? std::atof(dur) : 0.0;
    replay_active = !replay_rows.empty();
    EVLOG_info << "[REPLAY/supply] loaded " << replay_rows.size() << " rows from " << path
               << " duration_s=" << replay_duration_s << " active=" << replay_active;
}

// Interpolated (voltage, current) at the current replay time; clock starts on the first
// call (first export tick). Returns false when replay is inactive.
bool power_supply_DCImpl::replay_value(double& voltage, double& current) {
    if (!replay_active) {
        return false;
    }
    if (!replay_started) {
        replay_t0 = std::chrono::steady_clock::now();
        replay_started = true;
    }
    const double elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                               std::chrono::steady_clock::now() - replay_t0)
                               .count() /
                           1000.0;
    const double prof_total = replay_rows.back()[0];
    const double scale = (replay_duration_s > 0.0) ? (prof_total / replay_duration_s) : 1.0;
    double tau = elapsed * scale;
    if (tau < 0.0) {
        tau = 0.0;
    }
    if (tau > prof_total) {
        tau = prof_total;
    }
    size_t i = 0;
    while (i + 1 < replay_rows.size() && replay_rows[i + 1][0] < tau) {
        i++;
    }
    const auto& a = replay_rows[i];
    if (i + 1 < replay_rows.size()) {
        const auto& b = replay_rows[i + 1];
        const double span = b[0] - a[0];
        const double w = (span > 0.0) ? (tau - a[0]) / span : 0.0;
        voltage = a[1] + (b[1] - a[1]) * w;
        current = a[2] + (b[2] - a[2]) * w;
    } else {
        voltage = a[1];
        current = a[2];
    }
    return true;
}

void power_supply_DCImpl::init() {
    connector_voltage = 0.0;
    connector_current = 0.0;
    energy_import_total = 0.0;
    energy_export_total = 0.0;

    power_supply_thread_handle = std::thread(&power_supply_DCImpl::power_supply_worker, this);
}

static auto get_capabilities_from_config(const Conf& config) {
    types::power_supply_DC::Capabilities cap;

    cap.bidirectional = config.bidirectional;
    cap.current_regulation_tolerance_A = 2.0f;
    cap.peak_current_ripple_A = 2.0f;
    cap.max_export_voltage_V = static_cast<float>(config.max_voltage);
    cap.min_export_voltage_V = static_cast<float>(config.min_voltage);
    cap.max_export_current_A = static_cast<float>(config.max_current);
    cap.min_export_current_A = static_cast<float>(config.min_current);
    cap.max_export_power_W = static_cast<float>(config.max_power);
    cap.nominal_max_export_voltage_V = static_cast<float>(config.nominal_max_voltage);
    cap.nominal_min_export_voltage_V = static_cast<float>(config.nominal_min_voltage);
    cap.nominal_max_export_current_A = static_cast<float>(config.nominal_max_current);
    cap.nominal_min_export_current_A = static_cast<float>(config.nominal_min_current);
    cap.nominal_max_export_power_W = static_cast<float>(config.nominal_max_export_power);
    cap.max_import_voltage_V = static_cast<float>(config.max_voltage);
    cap.min_import_voltage_V = static_cast<float>(config.min_voltage);
    cap.max_import_current_A = static_cast<float>(config.max_current);
    cap.min_import_current_A = static_cast<float>(config.min_current);
    cap.max_import_power_W = static_cast<float>(config.max_power);
    cap.nominal_max_import_voltage_V = static_cast<float>(config.nominal_max_voltage);
    cap.nominal_min_import_voltage_V = static_cast<float>(config.nominal_min_voltage);
    cap.nominal_max_import_current_A = static_cast<float>(config.nominal_max_current);
    cap.nominal_min_import_current_A = static_cast<float>(config.nominal_min_current);
    cap.nominal_max_import_power_W = static_cast<float>(config.nominal_max_import_power);
    cap.conversion_efficiency_import = 0.85f;
    cap.conversion_efficiency_export = 0.9f;

    return cap;
}

void power_supply_DCImpl::ready() {
    publish_capabilities(get_capabilities_from_config(config));
}

void power_supply_DCImpl::handle_setMode(types::power_supply_DC::Mode& _mode,
                                         types::power_supply_DC::ChargingPhase& phase) {
    mode = _mode;
    charging_phase = phase; // only replay-override during the real Charging phase, not PreCharge

    EVLOG_info << "Set mode: " << types::power_supply_DC::mode_to_string(mode)
               << " ChargingPhase: " << types::power_supply_DC::charging_phase_to_string(phase);

    std::scoped_lock access_lock(power_supply_values_mutex);
    if ((mode == types::power_supply_DC::Mode::Off) || (mode == types::power_supply_DC::Mode::Fault)) {
        connector_voltage = 0.0;
        connector_current = 0.0;
    } else if (mode == types::power_supply_DC::Mode::Export) {
        connector_voltage = settings_connector_export_voltage;
        connector_current = settings_connector_max_export_current;
    } else if (mode == types::power_supply_DC::Mode::Import) {
        connector_voltage = settings_connector_import_voltage;
        connector_current = settings_connector_max_import_current;
    }

    mod->p_main->publish_mode(mode);
}

void power_supply_DCImpl::clampVoltageCurrent(double& voltage, double& current) {
    voltage = voltage < config.min_voltage   ? config.min_voltage
              : voltage > config.max_voltage ? config.max_voltage
                                             : voltage;

    current = current < config.min_current   ? config.min_current
              : current > config.max_current ? config.max_current
                                             : current;
}

void power_supply_DCImpl::handle_setExportVoltageCurrent(double& voltage, double& current) {
    double temp_voltage = voltage;
    double temp_current = current;

    clampVoltageCurrent(temp_voltage, temp_current);

    std::scoped_lock access_lock(power_supply_values_mutex);
    settings_connector_export_voltage = temp_voltage;
    settings_connector_max_export_current = temp_current;

    if (mode == types::power_supply_DC::Mode::Export) {
        connector_voltage = settings_connector_export_voltage;
        connector_current = settings_connector_max_export_current;
    }
}

void power_supply_DCImpl::handle_setImportVoltageCurrent(double& voltage, double& current) {
    double temp_voltage = voltage;
    double temp_current = current;

    clampVoltageCurrent(temp_voltage, temp_current);

    std::scoped_lock access_lock(power_supply_values_mutex);
    settings_connector_import_voltage = temp_voltage;
    settings_connector_max_import_current = temp_current;

    if (mode == types::power_supply_DC::Mode::Import) {
        connector_voltage = settings_connector_import_voltage;
        connector_current = -settings_connector_max_import_current;
    }
}

types::powermeter::Powermeter power_supply_DCImpl::power_meter_external() {
    types::powermeter::Powermeter powermeter;

    powermeter.timestamp = Everest::Date::to_rfc3339(date::utc_clock::now());
    powermeter.meter_id = "DC_POWERMETER";

    if (connector_current > 0) {
        energy_import_total += (connector_voltage * connector_current * LOOP_SLEEP_MS / 1000) / 3600;
    }
    if (connector_current < 0) {
        energy_export_total += (connector_voltage * -connector_current * LOOP_SLEEP_MS / 1000) / 3600;
    }

    powermeter.energy_Wh_import = {static_cast<float>(energy_import_total)};
    powermeter.energy_Wh_export = {static_cast<float>(energy_export_total)};

    powermeter.power_W = {static_cast<float>(connector_current * connector_voltage)};
    powermeter.current_A = {static_cast<float>(connector_current)};
    powermeter.voltage_V = {static_cast<float>(connector_voltage)};

    return powermeter;
}

void power_supply_DCImpl::power_supply_worker(void) {
    types::power_supply_DC::VoltageCurrent voltage_current;

    while (true) {
        if (power_supply_thread_handle.shouldExit()) {
            break;
        }

        // set interval for publishing
        std::this_thread::sleep_for(std::chrono::milliseconds(LOOP_SLEEP_MS));

        std::scoped_lock access_lock(power_supply_values_mutex);

        // Real-trace replay: while exporting (charging), override the simulated output with
        // the measured Zenodo curve so both the ISO present values and the OCPP powermeter
        // (derived from connector_voltage/current below) follow the real charging profile.
        if (!replay_inited) {
            replay_init();
        }
        if (replay_active && mode == types::power_supply_DC::Mode::Export &&
            charging_phase == types::power_supply_DC::ChargingPhase::Charging) {
            double r_voltage = 0.0, r_current = 0.0;
            if (replay_value(r_voltage, r_current)) {
                clampVoltageCurrent(r_voltage, r_current);
                connector_voltage = r_voltage;
                connector_current = r_current;
            }
        }

        voltage_current.voltage_V = static_cast<float>(connector_voltage);
        voltage_current.current_A = static_cast<float>(connector_current);

        mod->p_main->publish_voltage_current(voltage_current);
        mod->p_powermeter->publish_powermeter(power_meter_external());
    }
}
} // namespace main
} // namespace module
