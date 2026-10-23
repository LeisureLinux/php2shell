<?php
/**
 * The gadget.  On a real target this is a framework class whose __destruct
 * happens to be useful (Guzzle FileCookieJar / Symfony Process / Monolog
 * handlers ...).  This is a minimal stand-in.
 */
class Evil {
    public $cmd;
    public function __destruct() { if ($this->cmd) { @system($this->cmd); } }
}
