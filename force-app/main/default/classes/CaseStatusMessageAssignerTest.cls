/**
 * @description Unit tests for CaseStatusMessageAssigner decide/isIntakeOpenAt/isMatterActiveAt
 * @group Case Status Message Migration
 */
@IsTest
private class CaseStatusMessageAssignerTest {
    @IsTest
    static void testIsIntakeOpenAt_and_isMatterActiveAt() {
        Datetime nowDt = System.now();
        // Intake scenarios
        CaseStatusMessageAssigner.IntakeDTO iOpen = new CaseStatusMessageAssigner.IntakeDTO();
        iOpen.id = Id.valueOf('001000000000001AAA'); // dummy Id format ok in tests for DTO
        iOpen.createdDate = nowDt.addDays(-2);
        iOpen.matterId = null;
        iOpen.status = 'Open';
        System.assertEquals(true, CaseStatusMessageAssigner.isIntakeOpenAt(iOpen, nowDt));

        CaseStatusMessageAssigner.IntakeDTO iFuture = new CaseStatusMessageAssigner.IntakeDTO();
        iFuture.id = Id.valueOf('001000000000002AAA');
        iFuture.createdDate = nowDt.addDays(1);
        iFuture.matterId = null;
        iFuture.status = 'Open';
        System.assertEquals(false, CaseStatusMessageAssigner.isIntakeOpenAt(iFuture, nowDt), 'Future-created intake is not open at T');

        CaseStatusMessageAssigner.IntakeDTO iLinked = new CaseStatusMessageAssigner.IntakeDTO();
        iLinked.id = Id.valueOf('001000000000003AAA');
        iLinked.createdDate = nowDt.addDays(-1);
        iLinked.matterId = Id.valueOf('001000000000004AAA');
        iLinked.status = 'Open';
        System.assertEquals(false, CaseStatusMessageAssigner.isIntakeOpenAt(iLinked, nowDt), 'Linked to matter => not open');

        CaseStatusMessageAssigner.IntakeDTO iExcluded = new CaseStatusMessageAssigner.IntakeDTO();
        iExcluded.id = Id.valueOf('001000000000005AAA');
        iExcluded.createdDate = nowDt.addDays(-1);
        iExcluded.matterId = null;
        iExcluded.status = 'Turned Down';
        System.assertEquals(false, CaseStatusMessageAssigner.isIntakeOpenAt(iExcluded, nowDt), 'Excluded status => not open');

        // Matter scenarios
        CaseStatusMessageAssigner.MatterDTO mActive = new CaseStatusMessageAssigner.MatterDTO();
        mActive.id = Id.valueOf('001000000000006AAA');
        mActive.clientId = Id.valueOf('001000000000100AAA');
        mActive.createdDate = nowDt.addDays(-10);
        mActive.closedDate = null;
        System.assertEquals(true, CaseStatusMessageAssigner.isMatterActiveAt(mActive, nowDt), 'No closed date => active');

        CaseStatusMessageAssigner.MatterDTO mClosedEOD = new CaseStatusMessageAssigner.MatterDTO();
        mClosedEOD.id = Id.valueOf('001000000000007AAA');
        mClosedEOD.clientId = mActive.clientId;
        mClosedEOD.createdDate = nowDt.addDays(-10);
        mClosedEOD.closedDate = Date.today(); // end of day still >= now if now is earlier GMT same day
        System.assertEquals(true, CaseStatusMessageAssigner.isMatterActiveAt(mClosedEOD, Datetime.newInstanceGmt(Date.today().year(), Date.today().month(), Date.today().day(), 20, 0, 0)));

        CaseStatusMessageAssigner.MatterDTO mFuture = new CaseStatusMessageAssigner.MatterDTO();
        mFuture.id = Id.valueOf('001000000000008AAA');
        mFuture.clientId = mActive.clientId;
        mFuture.createdDate = nowDt.addDays(1);
        mFuture.closedDate = null;
        System.assertEquals(false, CaseStatusMessageAssigner.isMatterActiveAt(mFuture, nowDt), 'Future-created matter => not active at T');
    }

    @IsTest
    static void testDecideReturnsAllEligible() {
        Datetime nowDt = System.now();

        // Build 2 open intakes and 0 active matters
        List<CaseStatusMessageAssigner.IntakeDTO> intakes = new List<CaseStatusMessageAssigner.IntakeDTO>();
        for (Integer n = 1; n < 3; n++) {
            CaseStatusMessageAssigner.IntakeDTO i = new CaseStatusMessageAssigner.IntakeDTO();
            i.id = Id.valueOf('00100000000000' + String.valueOf(1+n) + 'AAA');
            i.createdDate = nowDt.addDays(-n-1);
            i.matterId = null;
            i.status = 'Open';
            intakes.add(i);
        }
        List<CaseStatusMessageAssigner.MatterDTO> matters = new List<CaseStatusMessageAssigner.MatterDTO>();

        CaseStatusMessageAssigner.Decision dIntakes = CaseStatusMessageAssigner.decide(Id.valueOf('001000000000200AAA'), nowDt, intakes, matters);
        System.assertEquals(2, dIntakes.openIntakesCount);
        System.assertEquals(true, dIntakes.intakeIds != null && dIntakes.intakeIds.size() == 2);
        System.assertEquals(0, dIntakes.activeMattersCount);
        System.assertEquals(null, dIntakes.matterIds);

        // Now no open intakes but 3 active matters
        intakes.clear();
        for (Integer n = 1; n < 4; n++) {
            CaseStatusMessageAssigner.MatterDTO m = new CaseStatusMessageAssigner.MatterDTO();
            m.id = Id.valueOf('00100000000003' + String.valueOf(1+n) + 'AAA');
            m.clientId = Id.valueOf('001000000000200AAA');
            m.createdDate = nowDt.addDays(-n-5);
            m.closedDate = null;
            matters.add(m);
        }
        CaseStatusMessageAssigner.Decision dMatters = CaseStatusMessageAssigner.decide(Id.valueOf('001000000000200AAA'), nowDt, intakes, matters);
        System.assertEquals(0, dMatters.openIntakesCount);
        System.assertEquals(3, dMatters.activeMattersCount);
        System.assertEquals(true, dMatters.matterIds != null && dMatters.matterIds.size() == 3);
    }
}