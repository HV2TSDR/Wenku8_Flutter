package org.mewx.wenku8_flutter;

import android.app.Activity;
import android.app.Instrumentation;
import android.os.Bundle;
import android.os.ResultReceiver;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/** Read-only requests through the app owner. Only coarse statuses leave it. */
public final class CatalogReadInstrumentation extends Instrumentation {
    private boolean unifiedOnly;
    @Override public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        unifiedOnly = arguments != null && "true".equals(arguments.getString("unifiedOnly"));
        start();
    }

    private String call(String method, String action) throws InterruptedException {
        CountDownLatch done = new CountDownLatch(1);
        AtomicReference<String> status = new AtomicReference<>("NO_RESULT");
        ResultReceiver receiver = new ResultReceiver(null) {
            @Override protected void onReceiveResult(int code, Bundle data) {
                status.set(data == null ? "EMPTY_RESULT" : data.getString("status", "EMPTY_RESULT"));
                done.countDown();
            }
        };
        Bundle args = new Bundle();
        if (action != null) args.putString("action", action);
        if ("publicationPage".equals(method)) {
            args.putInt("library", 1);
            args.putInt("page", 1);
        }
        WenkuHostPlugin.probeCatalogForPreview(getTargetContext(), method, args, receiver);
        if (!done.await(75, TimeUnit.SECONDS)) throw new IllegalStateException("probe timed out");
        return status.get();
    }

    @Override public void onStart() {
        Bundle result = new Bundle();
        try {
            if (!"org.mewx.wenku8_flutter.reader_preview".equals(getTargetContext().getPackageName())) {
                throw new IllegalStateException("preview only");
            }
            String active = call("hasSession", null);
            StringBuilder lines = new StringBuilder("ACCOUNT_SESSION=").append(active).append('\n');
            if ("PRESENT".equals(active)) {
                if (!unifiedOnly) {
                    lines.append("ACCOUNT_INFO=").append(call("accountRequest", "action=userinfo")).append('\n');
                    lines.append("CATEGORY_IDS=").append(call("accountRequest", "action=articlelist&sort=1&page=1")).append('\n');
                    lines.append("CATEGORY_META=").append(call("accountRequest", "action=novellist&sort=1&page=1&t=0")).append('\n');
                }
                lines.append("UNIFIED_CATEGORY=").append(call("publicationPage", null)).append('\n');
            }
            result.putString("stream", lines.toString());
            finish(Activity.RESULT_OK, result);
        } catch (Throwable failure) {
            String detail = failure instanceof LinkageError ? ":" + failure.getMessage() : "";
            result.putString("stream", "CATALOG_PROBE_FAILURE=" + failure.getClass().getSimpleName() + detail + "\n");
            finish(Activity.RESULT_CANCELED, result);
        }
    }
}
