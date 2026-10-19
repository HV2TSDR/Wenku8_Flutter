package org.mewx.wenku8_flutter

import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.os.Bundle

/** No credentials or network: device-keystore tests in the separate QA package. */
class SessionFixtureInstrumentation : Instrumentation() {
    private var fixture: String? = null
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        fixture = arguments?.getString("fixture")
        start()
    }

    override fun onStart() {
        val results = Bundle()
        var code = Activity.RESULT_OK
        var checks = 0
        val context = targetContext
        if (fixture == "speech" || fixture == "update") {
            try {
                check(context.packageName.endsWith(".render_probe"))
                if (fixture == "speech") SpeechFixture.run(context, results)
                else UpdateFixture.run(context, results)
                finish(Activity.RESULT_OK, results)
            } catch (failure: Throwable) {
                results.putString("stream", "${fixture!!.uppercase()}_FIXTURE_FAILURE=${failure.javaClass.simpleName}:${failure.message}\n")
                finish(Activity.RESULT_CANCELED, results)
            }
            return
        }
        try {
            check(context.packageName.endsWith(".render_probe"))
            val preferences = context.getSharedPreferences("wenku_account_session", Context.MODE_PRIVATE)
            val store = AccountSessionStore(context)
            store.write(null)
            check(store.read() == null); checks++
            val fixture = "SESSION-FIXTURE-1234567890"
            store.write(fixture)
            check(AccountSessionStore(context).read() == fixture); checks++
            val first = preferences.getString("sealed", null)!!
            check(!first.contains(fixture) && first.contains(":")); checks++
            store.write(fixture)
            check(preferences.getString("sealed", null) != first); checks++
            val fullJar = ApiSessionCookies.fromStored(fixture)
                .merge(listOf("jieqiUserInfo=fixture-reader; Path=/; HttpOnly"))
            store.write(fullJar.stored())
            check(ApiSessionCookies.fromStored(AccountSessionStore(context).read()!!) == fullJar); checks++
            check(!preferences.getString("sealed", null)!!.contains("fixture-reader")); checks++
            check(preferences.edit().putString("sealed", "corrupt").commit())
            check(store.read() == null && !preferences.contains("sealed")); checks++
            store.write(fixture)
            store.write(null)
            check(AccountSessionStore(context).read() == null); checks++
            results.putString("stream", "SESSION_FIXTURE_VERIFIED=empty,restore,sealed,nonce,full-cookie-jar,corruption,logout\n")
        } catch (failure: Throwable) {
            code = Activity.RESULT_CANCELED
            results.putString("stream", "SESSION_FIXTURE_FAILURE=${failure.javaClass.simpleName}\n")
        } finally {
            if (context.packageName.endsWith(".render_probe")) {
                AccountSessionStore(context).write(null)
            }
        }
        results.putInt("checks", checks)
        finish(code, results)
    }
}
