// Seeds a small demo dataset so the LWCs and batch have something to chew on.
// Run via: sf apex run -f scripts/apex/seedDemoData.apex
//
// Creates:
//   - 1 Account
//   - 3 Contacts on it
//   - 4 Opportunities (mix of qualifying / non-qualifying for the inactivity rule)
//   - 2 Tasks (one recent, one old) so LastActivityDate rolls up

Account demoAcc = new Account(Name = 'NimbusPoint Demo Co');
insert demoAcc;

List<Contact> contacts = new List<Contact>{
    new Contact(FirstName = 'Aria',  LastName = 'Watts',   AccountId = demoAcc.Id, Email = 'aria@demo.test'),
    new Contact(FirstName = 'Ben',   LastName = 'Okoye',   AccountId = demoAcc.Id, Email = 'ben@demo.test'),
    new Contact(FirstName = 'Carla', LastName = 'Vargas',  AccountId = demoAcc.Id, Email = 'carla@demo.test')
};
insert contacts;

List<Opportunity> opps = new List<Opportunity>{
    new Opportunity(Name = 'Demo: Stale High-Value', AccountId = demoAcc.Id,
        StageName = 'Prospecting', CloseDate = Date.today().addDays(45), Amount = 50000),
    new Opportunity(Name = 'Demo: Stale Mid-Value', AccountId = demoAcc.Id,
        StageName = 'Qualification', CloseDate = Date.today().addDays(30), Amount = 15000),
    new Opportunity(Name = 'Demo: Active Big Deal', AccountId = demoAcc.Id,
        StageName = 'Negotiation', CloseDate = Date.today().addDays(60), Amount = 80000),
    new Opportunity(Name = 'Demo: Low Value (excluded)', AccountId = demoAcc.Id,
        StageName = 'Prospecting', CloseDate = Date.today().addDays(20), Amount = 4000)
};
insert opps;

// One recent Task → keeps "Active Big Deal" off the at-risk list
insert new Task(
    Subject = 'Discovery call', Status = 'Completed',
    ActivityDate = Date.today().addDays(-2),
    Description = 'Walked through pricing options.',
    WhatId = opps[2].Id, WhoId = contacts[0].Id,
    Call_Outcome__c = 'Positive', Call_Notes_Source__c = 'Call Notes Logger'
);
// One old Task on Stale Mid-Value → still qualifies as inactive
insert new Task(
    Subject = 'Initial outreach', Status = 'Completed',
    ActivityDate = Date.today().addDays(-25),
    Description = 'Left voicemail.',
    WhatId = opps[1].Id, WhoId = contacts[1].Id,
    Call_Outcome__c = 'No Answer', Call_Notes_Source__c = 'Call Notes Logger'
);

System.debug('Seeded demo Account: ' + demoAcc.Id);
System.debug('Demo Opportunities: ' + opps);
