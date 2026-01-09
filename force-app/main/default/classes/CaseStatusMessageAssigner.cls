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
        public Id intakeId;
        public Id matterId;
        public Integer openIntakesCount;
        public Integer activeMattersCount;
        public static Decision none(Integer oi, Integer am) {
            Decision d = new Decision();
            d.openIntakesCount = oi;
            d.activeMattersCount = am;
            return d;
        }
    }

    /**
     * Compute assignment for a given Party and timepoint T using preloaded candidate collections.
     * - If exactly one open intake at T => select Intake
     * - Else if exactly one active matter at T => select Matter
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

        // Deterministic assignment logic
        if (oi == 1) {
            Decision d = new Decision();
            d.intakeId = openIntakes[0].id;
            d.openIntakesCount = oi;
            d.activeMattersCount = am;
            return d;
        }
        if (am == 1) {
            Decision d = new Decision();
            d.matterId = activeMatters[0].id;
            d.openIntakesCount = oi;
            d.activeMattersCount = am;
            return d;
        }
        return Decision.none(oi, am);
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

        // closedDate is Date-only; treat as end-of-day UTC
        Datetime closedEodUtc = Datetime.newInstanceGmt(m.closedDate.year(), m.closedDate.month(), m.closedDate.day(), 23, 59, 59);
        closedEodUtc = closedEodUtc.addMillis(999);
        return closedEodUtc.getTime() >= T.getTime();
    }
}
