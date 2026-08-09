package com.vault.vault.offload.handlers

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import com.vault.vault.offload.OffloadHandler
import com.vault.vault.offload.OffloadRequest
import com.vault.vault.offload.OffloadResponse
import org.json.JSONObject

class LocationHandler(private val context: Context) : OffloadHandler {
    override fun handle(req: OffloadRequest): OffloadResponse {
        val sub = req.argv.getOrNull(1) ?: "smoke"
        return when (sub) {
            "smoke" -> smoke()
            "get" -> get()
            else -> OffloadResponse.unknown("location: unknown subcommand '$sub'")
        }
    }

    private fun smoke(): OffloadResponse {
        if (!hasLocationPermission()) {
            return permissionNeeded()
        }
        return try {
            val lm = locationManager()
            val gps = lm.isProviderEnabled(LocationManager.GPS_PROVIDER)
            val network = lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
            val last = lastKnown(lm)
            val body = JSONObject()
                .put("gpsEnabled", gps)
                .put("networkEnabled", network)
                .put("hasLastKnown", last != null)
            if (last != null) {
                body.put("lat", last.latitude)
                body.put("lng", last.longitude)
            }
            OffloadResponse.ok("location smoke ok $body")
        } catch (e: SecurityException) {
            permissionNeeded(e.message)
        } catch (e: Exception) {
            OffloadResponse.error(1, "location smoke failed: ${e.message}")
        }
    }

    private fun get(): OffloadResponse {
        if (!hasLocationPermission()) {
            return permissionNeeded()
        }
        return try {
            val last = lastKnown(locationManager())
            if (last == null) {
                OffloadResponse.error(
                    1,
                    JSONObject()
                        .put("error", "location_unavailable")
                        .put(
                            "message",
                            "No last-known location; enable location services and wait for a fix",
                        )
                        .toString(),
                )
            } else {
                OffloadResponse.ok(
                    JSONObject()
                        .put("lat", last.latitude)
                        .put("lng", last.longitude)
                        .put("accuracy", last.accuracy.toDouble())
                        .put("provider", last.provider ?: "")
                        .put("time", last.time)
                        .toString(),
                )
            }
        } catch (e: SecurityException) {
            permissionNeeded(e.message)
        } catch (e: Exception) {
            OffloadResponse.error(1, "location get failed: ${e.message}")
        }
    }

    private fun lastKnown(lm: LocationManager): Location? {
        val providers = listOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.PASSIVE_PROVIDER,
        )
        var best: Location? = null
        for (p in providers) {
            try {
                // Prefer freshest cache even if provider is currently disabled.
                val loc = lm.getLastKnownLocation(p) ?: continue
                if (best == null || loc.time > best.time) {
                    best = loc
                }
            } catch (_: IllegalArgumentException) {
                // Provider not present on this device.
            }
        }
        return best
    }

    private fun locationManager(): LocationManager =
        context.getSystemService(Context.LOCATION_SERVICE) as LocationManager

    private fun hasLocationPermission(): Boolean {
        val fine = context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        val coarse = context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        return fine || coarse
    }

    private fun permissionNeeded(detail: String? = null): OffloadResponse {
        val msg = JSONObject()
            .put("error", "os_permission_required")
            .put("permission", "ACCESS_FINE_LOCATION|ACCESS_COARSE_LOCATION")
            .put(
                "message",
                "Grant location permission in Android Settings for Vault" +
                    (if (detail.isNullOrBlank()) "" else ": $detail"),
            )
            .toString()
        return OffloadResponse.error(1, msg)
    }
}
