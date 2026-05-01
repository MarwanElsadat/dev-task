/**
 * Custom exception thrown by the CallNotes service layer.
 * Distinguishes service-layer (user-facing, validation-style) errors from
 * unexpected platform errors (DML/SOQL/governor) so the handler can decide
 * how to surface them to the LWC.
 */
public inherited sharing class CallNotesException extends Exception {}
