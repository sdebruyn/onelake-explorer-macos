package telemetry

import "strconv"

// splitFields converts an Event into the App Insights properties +
// measurements split. String values go into properties, numeric values
// into measurements. The merged CommonProps are copied verbatim into
// properties so the sink does not need to know about them.
func splitFields(ev Event) (props map[string]string, meas map[string]float64) {
	props = make(map[string]string, len(ev.CommonProps)+4)
	for k, v := range ev.CommonProps {
		if v == "" {
			continue
		}
		props[k] = v
	}
	props["event"] = ev.Name
	if ev.TenantID != "" {
		props["tenantId"] = ev.TenantID
	}
	if ev.AccountAliasHash != "" {
		props["accountAliasHash"] = ev.AccountAliasHash
	}
	if ev.ErrorCode != "" {
		props["errorCode"] = ev.ErrorCode
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
