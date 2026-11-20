package io.tablecircle.prototype;

import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;
import android.os.PersistableBundle;

public final class ReplyReminderJob extends JobService {
    @Override public boolean onStartJob(JobParameters params) {
        var data = params.getExtras();
        ChatAlerts.remind(this, data.getInt("chat"), data.getInt("message"));
        return false;
    }

    @Override public boolean onStopJob(JobParameters params) {
        return true;
    }

    static synchronized boolean schedule(Context context, int chat, int message, long delay) {
        if (chat <= 0 || message <= 0 || delay <= 0 || delay > 604800000L) return false;
        var scheduler = context.getSystemService(JobScheduler.class);
        var service = new ComponentName(context, ReplyReminderJob.class);
        var jobs = scheduler.getAllPendingJobs();
        var usedIds = new java.util.HashSet<Integer>();
        int id = 0;
        for (var job : jobs) {
            if (job.getService().equals(service) && job.getExtras().getInt("message") == message) {
                id = job.getId();
                break;
            }
            usedIds.add(job.getId());
        }
        if (id == 0) {
            id = 10000;
            while (usedIds.contains(id)) id++;
        }
        var data = new PersistableBundle();
        data.putInt("chat", chat);
        data.putInt("message", message);
        try {
            return scheduler.schedule(new JobInfo.Builder(id, service).setPersisted(true)
                .setMinimumLatency(delay).setOverrideDeadline(delay + 60000L).setExtras(data)
                .build()) == JobScheduler.RESULT_SUCCESS;
        } catch (IllegalStateException unavailable) {
            return false;
        }
    }
}
