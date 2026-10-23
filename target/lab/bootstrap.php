<?php
/**
 * Application bootstrap (auto_prepend_file) -- lives OUTSIDE the webroot,
 * exactly like a real app's vendor/autoload.php.
 *
 * It must run BEFORE the session is read, otherwise the object we inject is
 * created as __PHP_Incomplete_Class and never gets a __destruct call.
 * That is why session.auto_start is Off: the bootstrap opens the session
 * itself, after the gadget class is available.
 */
require __DIR__ . '/gadget.php';

if (session_status() !== PHP_SESSION_ACTIVE) {
    session_start();
}
