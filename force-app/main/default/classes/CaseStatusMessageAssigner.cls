/**
 * @description Deterministic assignment logic for mapping Conversation Messages to Case_Status_Message__c
 *              using timepoint T = message.CreatedDate with strict cardinality rules.
 * @group Case Status Message Migration
 * @author Agentforce
 */
public with sharing class CaseStatusMessageAssigner {
    // DTOs for preloaded candidates
    public class MatterDTO {
        public Id id;
        public Id clientId; // litify_pm__Client__c
        public Datetime createdDate;
        public Date closedDate; // may be null (date-only)
    }
    public class IntakeDTO {
        public Id id;
        public Id clientId; // litify_pm__Client__c
        public Datetime createdDate;
        public Id matterId; // nullable
        public String status;
    }

    /**
     * Decision result for a single message at time T.
     */
    public class Decision {
        public List<Id> intakeIds;
        public List<Id> matterIds;
        public Integer openIntakesCount;
        public Integer activeMattersCount;
        public Decision initNone(Integer oi, Integer am) {
            this.intakeIds = new List<Id>();
            this.matterIds = new List<Id>();
            this.openIntakesCount = oi;
            this.activeMattersCount = am;
            return this;
        }
    }

    /**
     * Compute assignment for a given Party and timepoint T using preloaded candidate collections.
     * - If one or more open intakes at T => select ALL such Intakes
     * - Else if one or more active matters at T => select ALL such Matters
     * - Else => neither
     */
    public static Decision decide(Id partyId, Datetime T, List<IntakeDTO> allIntakesForParty, List<MatterDTO> allMattersForParty) {
        List<IntakeDTO> openIntakes = new List<IntakeDTO>();
        if (allIntakesForParty != null) {
            for (IntakeDTO i : allIntakesForParty) {
                if (isIntakeOpenAt(i, T)) {
                    openIntakes.add(i);
                }
            }
        }
        List<MatterDTO> activeMatters = new List<MatterDTO>();
        if (allMattersForParty != null) {
            for (MatterDTO m : allMattersForParty) {
                if (isMatterActiveAt(m, T)) {
                    activeMatters.add(m);
                }
            }
        }
        Integer oi = openIntakes.size();
        Integer am = activeMatters.size();

        // Updated assignment logic: duplicate across all eligible records at time T
        if (oi > 0) {
            Decision d = new Decision();
            d.intakeIds = new List<Id>();
            for (IntakeDTO i : openIntakes) {
                d.intakeIds.add(i.id);
            }
            d.openIntakesCount = oi;
            d.activeMattersCount = am;
            return d;
        }
        if (am > 0) {
            Decision d = new Decision();
            d.matterIds = new List<Id>();
            for (MatterDTO m : activeMatters) {
                d.matterIds.add(m.id);
            }
            d.openIntakesCount = oi;
            d.activeMattersCount = am;
            return d;
        }
        return new Decision().initNone(oi, am);
    }

    /**
     * Intake open at T if:
     * - CreatedDate ≤ T
     * - litify_pm__Matter__c == null
     * - status NOT IN (Turned Down, Referred Out)
     */
    public static Boolean isIntakeOpenAt(IntakeDTO i, Datetime T) {
        if (i == null || T == null) return false; // return-early
        if (i.createdDate == null) return false;
        if (i.createdDate > T) return false;
        if (i.matterId != null) return false;
        if (CaseStatusMessageEnums.isExcludedIntakeStatus(i.status)) return false;
        return true;
    }

    /**
     * Matter active at T if:
     * - CreatedDate ≤ T
     * - Closed_Date__c is null OR end-of-day(Closed_Date__c, UTC) ≥ T
     */
    public static Boolean isMatterActiveAt(MatterDTO m, Datetime T) {
        if (m == null || T == null || m.createdDate == null || m.createdDate > T) return false; // return-early
        if (m.closedDate == null) return true;

        // closedDate is Date-only; treat as end-of-day UTC (inclusive)
        Datetime closedEodUtc = Datetime.newInstanceGmt(m.closedDate.year(), m.closedDate.month(), m.closedDate.day(), 23, 59, 59);
        // Apex doesn't support addMilliseconds; emulate by adding one second and subtracting 1 ms via getTime math
        Long closedEodMillis = closedEodUtc.getTime() + 999;
        return closedEodMillis >= T.getTime();
    }
}