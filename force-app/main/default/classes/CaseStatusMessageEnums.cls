/**
 * @description Enums and constants for Case Status Message migration.
 * @group Case Status Message Migration
 * @author Agentforce
 */
public with sharing class CaseStatusMessageEnums {
    /**
     * Intake statuses that disqualify an Intake from being considered "open" at time T.
     * Use ALL_CAPS_SNAKE_CASE per a4d rules.
     */
    public enum INTAKE_EXCLUDED_STATUS {
        TURNED_DOWN,
        REFERRED_OUT
    }

    /**
     * Utility to normalize Intake status strings to enum where possible.
     */
    public static Boolean isExcludedIntakeStatus(String status) {
        if (String.isBlank(status)) return false;
        String norm = status.trim().toUpperCase().replace(' ', '_');
        for (INTAKE_EXCLUDED_STATUS e : INTAKE_EXCLUDED_STATUS.values()) {
            if (e.name() == norm) return true;
        }
        return false;
    }
}
