package telemetry

import "strconv"

// splitFields converts an Event into the App Insights properties +
// measurements split. String values go into properties, numeric values
// into measurements.
//
// Every property value is routed through [scrubProperty] (and the error
// code through [SafeErrorCode]) here, at the single boundary where an
// Event becomes sink-bound data. That makes the privacy promise — no UPN,
// path, workspace, or file name leaves the device — structural: a careless
// or future caller that stuffs a path into CommonProps cannot leak it,
// because this function is the only producer of the property map the sink
// sends.
func splitFields(ev Event) (props map[string]string, meas map[string]float64) {
	props = make(map[string]string, len(ev.CommonProps)+4)
	for k, v := range ev.CommonProps {
		if v == "" {
			continue
		}
		props[k] = scrubProperty(v)
	}
	props["event"] = scrubProperty(ev.Name)
	if ev.TenantID != "" {
		props["tenantId"] = scrubProperty(ev.TenantID)
	}
	if ev.AccountAliasHash != "" {
		props["accountAliasHash"] = scrubProperty(ev.AccountAliasHash)
	}
	if ev.ErrorCode != "" {
		props["errorCode"] = SafeErrorCode(ev.ErrorCode)
	}
	if ev.Success != nil {
		props["success"] = strconv.FormatBool(*ev.Success)
	}

	if ev.DurationMs != 0 || ev.BytesTransferred != 0 || ev.ItemsChanged != 0 {
		meas = make(map[string]float64, 3)
		if ev.DurationMs != 0 {
			meas["durationMs"] = float64(ev.DurationMs)
		}
		if ev.BytesTransferred != 0 {
			meas["bytesTransferred"] = float64(ev.BytesTransferred)
		}
		if ev.ItemsChanged != 0 {
			meas["itemsChanged"] = float64(ev.ItemsChanged)
		}
	}
	return props, meas
}
