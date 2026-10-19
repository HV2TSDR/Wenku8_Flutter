package org.mewx.wenku8_flutter

/** Resolution-preserving selection, without assuming a particular panel rate. */
internal object RefreshRatePolicy {
    data class Mode(val id: Int, val width: Int, val height: Int, val rate: Float)
    data class Preference(val modeId: Int, val rate: Float)

    fun select(sdk: Int, current: Mode, modes: List<Mode>, target: Float = 0f): Preference? {
        if (target == -1f) return Preference(0, 0f)
        val available = modes.asSequence()
            .filter { it.width == current.width && it.height == current.height }
            .filter { it.rate.isFinite() && it.rate > 0f }
            .toList()
        val eligible = if (target > 0f) available.filter { it.rate <= target + .5f }.ifEmpty { available.minByOrNull { it.rate }?.let { listOf(it) } ?: emptyList() } else available
        val fastest = eligible.asSequence()
            .maxWithOrNull(compareBy<Mode> { it.rate }.thenBy { it.id == current.id })
            ?: return null
        // Before API 34 a rate-only window preference applies to the DEFAULT
        // resolution, which need not be the resolution the user has selected.
        return Preference(if (sdk >= 34) 0 else fastest.id, fastest.rate)
    }

    fun rates(current: Mode, modes: List<Mode>): List<Float> = modes
        .filter { it.width == current.width && it.height == current.height && it.rate.isFinite() && it.rate > 0f }
        .map { it.rate }.sorted().fold(mutableListOf<Float>()) { rates, rate ->
            if (rates.none { kotlin.math.abs(it - rate) < .5f }) rates.add(rate)
            rates
        }
}

/** One vote per live surface/rate, not one vote per layout or rendered frame. */
internal class SurfaceRateVote {
    private var applied: Float? = null
    fun apply(rate: Float, valid: Boolean, submit: (Float) -> Unit): Boolean {
        if (!valid) { applied = null; return false }
        if (applied == rate) return false
        submit(rate)
        applied = rate
        return true
    }
    fun invalidate() { applied = null }
}
