<?php
/**
 * The php_serialize reader.
 *
 * On a real target this is any endpoint whose session.serialize_handler is
 * php_serialize.  It only has to start the session -- the payload does the
 * rest while the file is decoded.
 */
if (session_status() !== PHP_SESSION_ACTIVE) {
    session_start();
}
