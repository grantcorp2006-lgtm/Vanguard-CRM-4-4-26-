// Callback Notifications — exact-timer system with Web Notifications API
(function () {
    'use strict';

    console.log('🔔 Loading Callback Notification System (exact-timer v2)...');

    // ── State ──────────────────────────────────────────────────────────────────
    let callbackNotifications = JSON.parse(localStorage.getItem('callbackNotifications') || '[]');

    // Map of alarmKey → timeoutId  (value -1 = handled, no active timeout)
    const scheduledAlarms = new Map();

    // Email keys sent this session (prevent duplicates)
    const sentEmailKeys = new Set();

    // ── Browser Notification permission ───────────────────────────────────────
    function requestBrowserPermission() {
        if (!('Notification' in window)) return;
        if (Notification.permission === 'default') {
            Notification.requestPermission().then(p =>
                console.log('🔔 Browser notification permission:', p)
            );
        }
    }

    function fireBrowserNotification(title, body, leadId) {
        if (!('Notification' in window) || Notification.permission !== 'granted') return;
        try {
            const n = new Notification(title, {
                body,
                icon: '/favicon.ico',
                tag: `cb_${leadId}`,
                requireInteraction: true
            });
            n.onclick = () => {
                window.focus();
                if (typeof viewLead === 'function') viewLead(leadId);
                n.close();
            };
        } catch (e) { console.warn('Browser notification error:', e); }
    }

    // ── Lead lookup helper ─────────────────────────────────────────────────────
    // Called at FIRE time so we always have current localStorage data
    function getLeadData(leadId) {
        try {
            const leads = JSON.parse(localStorage.getItem('insurance_leads') || '[]');
            const lead  = leads.find(l => String(l.id) === String(leadId));
            if (lead) return lead;
        } catch (e) { /* ignore */ }
        // Fallback minimal object so the alarm still fires
        return { id: leadId, name: `Lead #${leadId}`, phone: '', assignedTo: '' };
    }

    // ── Core scheduler ─────────────────────────────────────────────────────────
    // NOTE: We do NOT require lead data here — look it up only at fire time.
    // This prevents the case where insurance_leads hasn't loaded yet from
    // silently dropping all alarms.
    function scheduleAlarms() {
        let callbacks;
        try {
            callbacks = JSON.parse(localStorage.getItem('scheduled_callbacks') || '{}');
        } catch (e) {
            console.error('🔔 Error reading scheduled_callbacks:', e);
            return;
        }

        const now = Date.now();
        let scheduled = 0;

        Object.keys(callbacks).forEach(leadId => {
            (callbacks[leadId] || []).forEach(cb => {
                if (cb.completed) return;

                const cbId  = String(cb.id || cb.dateTime || Date.now());
                const cbTs  = new Date(cb.dateTime).getTime();
                if (isNaN(cbTs)) {
                    console.warn('🔔 Invalid dateTime for callback:', cb);
                    return;
                }
                const msOut = cbTs - now;

                // ── 30-minute warning ─────────────────────────────────────
                const warn30Key    = `${leadId}_${cbId}_30min`;
                const msUntilWarn  = msOut - 30 * 60 * 1000;

                if (!scheduledAlarms.has(warn30Key)) {
                    if (msUntilWarn > 0) {
                        // Fires in the future
                        const tid = setTimeout(() => {
                            fireAlarm(leadId, cb, '30min');
                            scheduledAlarms.delete(warn30Key);
                        }, msUntilWarn);
                        scheduledAlarms.set(warn30Key, tid);
                        console.log(`⏰ 30-min alarm set for lead ${leadId} in ${Math.round(msUntilWarn/60000)}m`);
                        scheduled++;
                    } else if (msUntilWarn > -10 * 60 * 1000 && msOut > 0) {
                        // Missed 30-min window by < 10 min but call not yet due — warn now
                        scheduledAlarms.set(warn30Key, -1);
                        setTimeout(() => fireAlarm(leadId, cb, '30min'), 0);
                    } else {
                        scheduledAlarms.set(warn30Key, -1); // too late for warning
                    }
                } else {
                    // Key exists — check if a live timer was throttled and is now overdue
                    const tid = scheduledAlarms.get(warn30Key);
                    if (tid !== -1 && msUntilWarn <= 0 && msUntilWarn > -10 * 60 * 1000 && msOut > 0) {
                        clearTimeout(tid);
                        scheduledAlarms.set(warn30Key, -1);
                        console.log(`⏰ 30-min alarm was throttled, firing now for lead ${leadId}`);
                        setTimeout(() => fireAlarm(leadId, cb, '30min'), 0);
                    }
                }

                // ── Due-now alarm ─────────────────────────────────────────
                const dueKey = `${leadId}_${cbId}_due`;

                if (!scheduledAlarms.has(dueKey)) {
                    if (msOut > 0) {
                        // Fires at exact moment
                        const tid = setTimeout(() => {
                            fireAlarm(leadId, cb, 'due');
                            scheduledAlarms.delete(dueKey);
                        }, msOut);
                        scheduledAlarms.set(dueKey, tid);
                        console.log(`⏰ Due-now alarm set for lead ${leadId} in ${Math.round(msOut/1000)}s`);
                        scheduled++;
                    } else if (msOut >= -30 * 60 * 1000) {
                        // Overdue within 30-min grace window (e.g. page just refreshed)
                        scheduledAlarms.set(dueKey, -1);
                        setTimeout(() => fireAlarm(leadId, cb, 'due'), 0);
                    } else {
                        scheduledAlarms.set(dueKey, -1); // more than 30 min overdue, skip
                    }
                } else {
                    // Key exists — check if a live timer was throttled and is now overdue
                    const tid = scheduledAlarms.get(dueKey);
                    if (tid !== -1 && msOut <= 0 && msOut >= -30 * 60 * 1000) {
                        clearTimeout(tid);
                        scheduledAlarms.set(dueKey, -1);
                        console.log(`⏰ Due-now alarm was throttled, firing now for lead ${leadId}`);
                        setTimeout(() => fireAlarm(leadId, cb, 'due'), 0);
                    }
                }
            });
        });

        if (scheduled > 0) console.log(`🔔 Scheduled ${scheduled} alarm(s)`);
    }

    // ── Fire an alarm ──────────────────────────────────────────────────────────
    function fireAlarm(leadId, cb, type) {
        const isUrgent  = type === 'due';
        const lead      = getLeadData(leadId);   // look up NOW, not at schedule time
        const cbTime    = new Date(cb.dateTime);
        const fmtTime   = cbTime.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', hour12: true });
        const notifId   = `cb_${leadId}_${cb.id || cb.dateTime}_${type}`;

        // Session dedup: if we already fired this alarm this session, skip popup/sound
        // but still update badge
        if (callbackNotifications.find(n => n.id === notifId)) {
            console.log(`🔔 Alarm already fired this session: ${notifId}`);
            return;
        }

        const title   = isUrgent ? '🔥 CALL DUE NOW!'              : '⏰ Call Due in 30 Minutes';
        const message = isUrgent ? `URGENT: Call now with ${lead.name}` : `Scheduled call with ${lead.name}`;

        const notification = {
            id: notifId,
            type: isUrgent ? 'callback_due' : 'callback_reminder',
            title,
            message,
            leadId: String(leadId),
            leadName: lead.name,
            leadPhone: lead.phone,
            assignedAgent: lead.assignedTo || 'Unassigned',
            callbackTime: cb.dateTime,
            callbackTimeFormatted: fmtTime,
            callbackNotes: cb.notes,
            createdAt: new Date().toISOString(),
            read: false,
            actionable: true,
            urgent: isUrgent,
            dismissedBy: {}
        };

        callbackNotifications.push(notification);
        saveNotifications();
        updateNotificationDisplay();
        updateNotificationBadge();

        showPopupNotification(notification);
        fireBrowserNotification(title, `${lead.name} · ${fmtTime}`, leadId);
        playNotificationSound(notification);

        if (!isUrgent) sendEmailReminder(notification);

        console.log(`🔔 Alarm FIRED [${type}] for ${lead.name} at ${fmtTime}`);
    }

    // ── Popup ──────────────────────────────────────────────────────────────────
    function showPopupNotification(notification) {
        try {
            const existing = document.querySelector('.callback-popup-notification');
            if (existing) existing.remove();

            const popup = document.createElement('div');
            popup.className = 'callback-popup-notification';
            popup.innerHTML = `
                <div class="popup-content ${notification.urgent ? 'urgent' : ''}">
                    <div class="popup-icon">
                        <i class="fas fa-phone" style="color:${notification.urgent ? '#dc2626' : '#059669'};"></i>
                    </div>
                    <div class="popup-text">
                        <div class="popup-title">${notification.title}</div>
                        <div class="popup-message">${notification.message}</div>
                        <div class="popup-time">${notification.callbackTimeFormatted}</div>
                    </div>
                    <div class="popup-actions">
                        <button class="popup-call-btn" onclick="CallbackNotifications.handleCallNow('${notification.leadId}','${notification.leadPhone || ''}')">
                            <i class="fas fa-phone"></i> CALL
                        </button>
                        <button class="popup-dismiss-btn" onclick="CallbackNotifications.dismissPopup()">
                            <i class="fas fa-times"></i>
                        </button>
                    </div>
                </div>`;

            document.body.insertBefore(popup, document.body.firstChild);

            const delay = notification.urgent ? 30000 : 15000;
            setTimeout(() => {
                const p = document.querySelector('.callback-popup-notification');
                if (p) { p.style.transform = 'translateY(-100%)'; setTimeout(() => p.remove(), 300); }
            }, delay);

            console.log(`🔔 Popup shown for ${notification.leadName}`);
        } catch (e) {
            console.error('Error showing popup:', e);
        }
    }

    // ── Sound ──────────────────────────────────────────────────────────────────
    function playNotificationSound(notification) {
        try {
            let audio = document.querySelector('#callback-notification-audio');
            if (!audio) {
                audio = document.createElement('audio');
                audio.id = 'callback-notification-audio';
                audio.preload = 'auto';
                document.body.appendChild(audio);
            }
            audio.src = 'https://github.com/Corptech02/LLCinfo/blob/main/strong-minded-ringtone.ogg?raw=true';

            if (notification.urgent) {
                let count = 0;
                const next = () => { audio.play().catch(() => {}); if (++count < 3) setTimeout(next, 1500); };
                next();
            } else {
                audio.play().catch(() => {});
            }
        } catch (e) { /* autoplay policy — silent fail */ }
    }

    // ── Email ──────────────────────────────────────────────────────────────────
    function sendEmailReminder(notification) {
        const emailKey = `email_${notification.leadId}_${notification.callbackTime}`;
        if (sentEmailKeys.has(emailKey)) return;
        sentEmailKeys.add(emailKey);

        const sessionData = JSON.parse(sessionStorage.getItem('vanguard_user') || '{}');
        const userEmail   = sessionData.email;
        if (!userEmail) { console.log('🔔 No user email in session, skipping email reminder'); return; }

        const cbTime      = new Date(notification.callbackTime);
        const formattedDT = cbTime.toLocaleDateString('en-US', {
            weekday: 'long', year: 'numeric', month: 'long',
            day: 'numeric', hour: 'numeric', minute: '2-digit', hour12: true
        });

        const html = `
            <div style="font-family:Arial,sans-serif;max-width:600px;margin:0 auto">
                <div style="background:linear-gradient(135deg,#dc2626,#ef4444);color:white;padding:20px;text-align:center">
                    <h1 style="margin:0">🔔 Callback Reminder</h1>
                    <p style="font-size:18px;margin:8px 0 0">30 Minutes Until Scheduled Call</p>
                </div>
                <div style="padding:30px;background:#f9fafb">
                    <div style="background:white;padding:20px;border-radius:8px;border-left:4px solid #dc2626">
                        <h2 style="margin-top:0;color:#1f2937">Callback Details</h2>
                        <ul style="list-style:none;padding:0;margin:0">
                            <li style="margin-bottom:10px"><strong>📋 Lead:</strong> ${notification.leadName}</li>
                            <li style="margin-bottom:10px"><strong>📞 Phone:</strong> ${notification.leadPhone || 'Not provided'}</li>
                            <li style="margin-bottom:10px"><strong>🕒 Scheduled:</strong> ${formattedDT}</li>
                            <li style="margin-bottom:10px"><strong>📝 Notes:</strong> ${notification.callbackNotes || 'No notes'}</li>
                        </ul>
                    </div>
                </div>
            </div>`;

        fetch('/api/send-callback-reminder', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                to: userEmail,
                subject: `🔔 Callback in 30 min — ${notification.leadName}`,
                html
            })
        })
        .then(r => r.json())
        .then(d => { if (d.success) console.log(`✅ Reminder email sent for ${notification.leadName}`); else console.error('❌ Email failed:', d.error); })
        .catch(e => console.error('❌ Email error:', e));
    }

    // ── Sidebar display ────────────────────────────────────────────────────────
    function updateNotificationDisplay() {
        const el = document.querySelector('.notification-sidebar-content');
        if (!el) return;

        cleanupOldNotifications();

        const sessionData = JSON.parse(sessionStorage.getItem('vanguard_user') || '{}');
        const currentUser = sessionData.username || '';

        const active = callbackNotifications
            .filter(n => !isNotificationExpired(n))
            .filter(n => !(n.dismissedBy && n.dismissedBy[currentUser]))
            .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));

        if (active.length === 0) {
            el.innerHTML = `
                <div class="notification-empty-state">
                    <i class="fas fa-bell-slash"></i>
                    <p>No notifications yet</p>
                    <small>You'll see important updates here</small>
                </div>`;
        } else {
            el.innerHTML = `<div class="notifications-list">${active.map(generateNotificationHTML).join('')}</div>`;
            addNotificationClickHandlers();
        }
    }

    function generateNotificationHTML(notification) {
        const timeAgo = getTimeAgo(new Date(notification.createdAt));
        const readClass = notification.read ? 'read' : 'unread';
        let agent = notification.assignedAgent;
        if (!agent && notification.leadId) {
            const lead = getLeadData(notification.leadId);
            agent = lead.assignedTo || 'Unknown';
        }
        return `
            <div class="notification-item ${readClass} ${notification.urgent ? 'urgent-notification' : ''}" data-notification-id="${notification.id}">
                <button class="dismiss-btn-top-right" onclick="CallbackNotifications.dismissNotification('${notification.id}')" title="Dismiss">
                    <i class="fas fa-times"></i>
                </button>
                <div class="notification-icon">
                    <i class="fas fa-phone" style="color:${notification.urgent ? '#dc2626' : '#059669'};"></i>
                </div>
                <div class="notification-content">
                    <div class="notification-title">${notification.title}</div>
                    <div class="notification-message">${notification.message}</div>
                    <div class="notification-details">
                        <span class="callback-time">${notification.callbackTimeFormatted}</span>
                        ${notification.leadPhone ? `<span class="lead-phone">${notification.leadPhone}</span>` : ''}
                        ${agent ? `<span class="assigned-agent">Assigned: ${agent}</span>` : ''}
                    </div>
                    <div class="notification-time">${timeAgo}</div>
                </div>
                <div class="notification-actions">
                    <button class="view-lead-btn" onclick="CallbackNotifications.handleViewLead('${notification.leadId}')" title="View Lead">
                        <i class="fas fa-user"></i>
                    </button>
                </div>
            </div>`;
    }

    function addNotificationClickHandlers() {
        document.querySelectorAll('.notification-item').forEach(item => {
            item.addEventListener('click', e => {
                if (!e.target.closest('.notification-actions') && !e.target.closest('.dismiss-btn-top-right')) {
                    markAsRead(item.getAttribute('data-notification-id'));
                }
            });
        });
    }

    // ── Badge ──────────────────────────────────────────────────────────────────
    function updateNotificationBadge() {
        const unread = callbackNotifications.filter(n => !n.read && !isNotificationExpired(n)).length;
        const btn    = document.querySelector('.notification-btn');
        if (!btn) return;
        let badge = btn.querySelector('.notification-badge');
        if (unread > 0) {
            if (!badge) { badge = document.createElement('span'); badge.className = 'notification-badge'; btn.appendChild(badge); }
            badge.textContent = unread > 99 ? '99+' : unread;
            badge.style.display = 'inline-block';
        } else if (badge) {
            badge.style.display = 'none';
        }
    }

    // ── Helpers ────────────────────────────────────────────────────────────────
    function cleanupOldNotifications() {
        const before = callbackNotifications.length;
        callbackNotifications = callbackNotifications.filter(n => !isNotificationExpired(n));
        if (callbackNotifications.length !== before) saveNotifications();
    }

    function isNotificationExpired(n) {
        const now         = Date.now();
        const cbTime      = new Date(n.callbackTime).getTime();
        const createdTime = new Date(n.createdAt).getTime();
        if (now > cbTime + 60 * 60 * 1000)          return true; // 1h after callback
        if (now > createdTime + 24 * 60 * 60 * 1000) return true; // 24h old
        return false;
    }

    function getTimeAgo(date) {
        const diff  = Date.now() - date.getTime();
        const mins  = Math.floor(diff / 60000);
        const hours = Math.floor(diff / 3600000);
        if (mins < 1)   return 'Just now';
        if (mins < 60)  return `${mins}m ago`;
        if (hours < 24) return `${hours}h ago`;
        return date.toLocaleDateString();
    }

    function saveNotifications() {
        localStorage.setItem('callbackNotifications', JSON.stringify(callbackNotifications));
    }

    function markAsRead(notificationId) {
        const n = callbackNotifications.find(n => n.id === notificationId);
        if (n && !n.read) {
            n.read = true;
            saveNotifications();
            updateNotificationBadge();
            const el = document.querySelector(`[data-notification-id="${notificationId}"]`);
            if (el) { el.classList.remove('unread'); el.classList.add('read'); }
        }
    }

    // ── Visibility-change handler ──────────────────────────────────────────────
    // Browsers throttle/suspend setTimeout in background tabs.
    // When the user switches back to this tab, immediately re-scan for overdue
    // callbacks so they are never silently missed.
    function onVisibilityChange() {
        if (document.visibilityState === 'visible') {
            console.log('🔔 Tab became visible — clearing stale timers and re-scanning callbacks');
            cleanupOldNotifications();
            // Clear any live timers whose callback time has already passed so
            // scheduleAlarms() will catch them in the overdue grace-window branch
            const now2 = Date.now();
            scheduledAlarms.forEach((tid, key) => {
                if (tid !== -1) {
                    // Extract leadId + cbId + type from key
                    const type = key.endsWith('_due') ? 'due' : '30min';
                    // We can't easily get cbTs from the key alone, so clear all live
                    // timers — scheduleAlarms will re-set any that are still future
                    clearTimeout(tid);
                    scheduledAlarms.delete(key);
                }
            });
            scheduleAlarms();
            updateNotificationBadge();
        }
    }

    // ── Public API ─────────────────────────────────────────────────────────────
    const CallbackNotifications = {
        init() {
            requestBrowserPermission();
            cleanupOldNotifications();
            updateNotificationDisplay();
            updateNotificationBadge();

            // Schedule exact-fire alarms for all existing callbacks
            scheduleAlarms();

            // Re-scan every 30 seconds (catch throttled timers and new callbacks)
            setInterval(() => {
                cleanupOldNotifications();
                scheduleAlarms();
                updateNotificationBadge();
            }, 30 * 1000);

            // Re-scan when tab becomes visible (handles background-tab throttling)
            document.addEventListener('visibilitychange', onVisibilityChange);

            // Re-scan when another tab writes to scheduled_callbacks (cross-tab support)
            window.addEventListener('storage', e => {
                if (e.key === 'scheduled_callbacks') {
                    console.log('🔔 scheduled_callbacks changed in another tab — rescheduling');
                    scheduleAlarms();
                }
            });

            console.log('✅ Exact-timer notification system active');
        },

        // Called immediately after a new callback is saved
        refresh() {
            console.log('🔔 refresh() — rescheduling alarms');
            scheduleAlarms();
        },

        dismissPopup() {
            const p = document.querySelector('.callback-popup-notification');
            if (p) { p.style.transform = 'translateY(-100%)'; setTimeout(() => p.remove(), 300); }
        },

        dismissNotification(notificationId) {
            const sessionData = JSON.parse(sessionStorage.getItem('vanguard_user') || '{}');
            const currentUser = sessionData.username || '';
            const n = callbackNotifications.find(n => n.id === notificationId);
            if (n) {
                if (!n.dismissedBy) n.dismissedBy = {};
                n.dismissedBy[currentUser] = true;
                saveNotifications();
                updateNotificationDisplay();
                updateNotificationBadge();
            }
        },

        handleCallNow(leadId, phone) {
            if (typeof handleReachOutCall === 'function') handleReachOutCall(leadId, phone);
            else window.open(`tel:${phone}`, '_self');
            if (typeof closeNotificationSidebar === 'function') closeNotificationSidebar();
        },

        handleViewLead(leadId) {
            if (typeof viewLead === 'function') viewLead(leadId);
            if (typeof closeNotificationSidebar === 'function') closeNotificationSidebar();
        },

        markAsRead,
        updateNotificationDisplay,
        updateNotificationBadge,

        addNotification(notification) {
            notification.id        = notification.id        || `custom_${Date.now()}`;
            notification.createdAt = notification.createdAt || new Date().toISOString();
            notification.read      = notification.read      || false;
            callbackNotifications.push(notification);
            saveNotifications();
            updateNotificationDisplay();
            updateNotificationBadge();
        }
    };

    window.CallbackNotifications = CallbackNotifications;

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', () => CallbackNotifications.init());
    } else {
        CallbackNotifications.init();
    }

    console.log('✅ Callback Notifications loaded (exact-timer v2)');
})();
