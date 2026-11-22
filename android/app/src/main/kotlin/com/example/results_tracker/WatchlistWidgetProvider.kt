package com.example.results_tracker

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/** Home-screen widget: today's results and the watchlist's next events. */
class WatchlistWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        appWidgetIds.forEach { id ->
            val views = RemoteViews(context.packageName, R.layout.watchlist_widget).apply {
                setTextViewText(R.id.widget_title, widgetData.getString("title", "Results Tracker"))
                setTextViewText(R.id.widget_today, widgetData.getString("today", "Open the app to load data"))
                setTextViewText(R.id.widget_events, widgetData.getString("events", ""))
                setTextViewText(R.id.widget_updated, widgetData.getString("updated", ""))
                setOnClickPendingIntent(
                    R.id.widget_root,
                    HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java),
                )
            }
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
