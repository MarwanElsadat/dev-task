import { LightningElement, api, wire, track } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { getRecord, getFieldValue } from "lightning/uiRecordApi";
import { refreshApex } from "@salesforce/apex";
import LightningConfirm from "lightning/confirm";

import OPP_ACCOUNT_ID from "@salesforce/schema/Opportunity.AccountId";

import logCallNote from "@salesforce/apex/CallNotesHandler.logCallNote";
import getRecentCallNotes from "@salesforce/apex/CallNotesHandler.getRecentCallNotes";
import updateCallNote from "@salesforce/apex/CallNotesHandler.updateCallNote";
import deleteCallNote from "@salesforce/apex/CallNotesHandler.deleteCallNote";

const RECENT_LIMIT = 5;

const OUTCOMES = [
  { label: "Positive", value: "Positive" },
  { label: "Neutral", value: "Neutral" },
  { label: "Negative", value: "Negative" },
  { label: "No Answer", value: "No Answer" }
];

const OUTCOME_PILL = {
  Positive: "slds-badge slds-theme_success",
  Neutral: "slds-badge",
  Negative: "slds-badge slds-theme_error",
  "No Answer": "slds-badge slds-theme_warning"
};

export default class CallNotesLogger extends LightningElement {
  @api recordId; // Opportunity Id
  accountId; // resolved from getRecord wire

  // Form state
  contactId = null;
  callDate = new Date().toISOString().slice(0, 10);
  outcome = "";
  notes = "";
  isSaving = false;

  // Recent notes
  @track recentNotes = [];
  isLoadingRecent = true;
  wiredNotesResult; // for refreshApex

  outcomeOptions = OUTCOMES;

  // ------------------------------------------------------------------ //
  // Wired data
  // ------------------------------------------------------------------ //

  @wire(getRecord, { recordId: "$recordId", fields: [OPP_ACCOUNT_ID] })
  wiredOpp({ data, error }) {
    if (data) {
      this.accountId = getFieldValue(data, OPP_ACCOUNT_ID);
    } else if (error) {
      this.toast("Error", "Could not load Opportunity.", "error");
    }
  }

  @wire(getRecentCallNotes, {
    opportunityId: "$recordId",
    limitSize: RECENT_LIMIT
  })
  wiredRecent(result) {
    this.wiredNotesResult = result;
    this.isLoadingRecent = false;
    if (result.data) {
      this.recentNotes = result.data.map((row) => ({
        ...row,
        Who: row.Who || { Name: null },
        editing: false,
        draftNotes: row.Description,
        draftOutcome: row.Call_Outcome__c,
        draftDate: row.ActivityDate,
        pillClass: OUTCOME_PILL[row.Call_Outcome__c] || "slds-badge"
      }));
    } else if (result.error) {
      this.recentNotes = [];
    }
  }

  // ------------------------------------------------------------------ //
  // Derived UI state
  // ------------------------------------------------------------------ //

  get charsUsed() {
    return (this.notes || "").length;
  }

  get hasRecent() {
    return this.recentNotes && this.recentNotes.length > 0;
  }

  get isSubmitDisabled() {
    return (
      this.isSaving ||
      !this.notes ||
      !this.notes.trim() ||
      this.notes.length > 1000 ||
      !this.outcome ||
      !this.callDate
    );
  }

  // lightning-record-picker filter — restrict to Contacts on this Opp's Account.
  // Returns an empty filter while accountId is unknown so the picker still
  // renders but produces no results.
  get contactFilter() {
    if (!this.accountId) return {};
    return {
      criteria: [
        { fieldPath: "AccountId", operator: "eq", value: this.accountId }
      ]
    };
  }
  get contactMatchingInfo() {
    return {
      primaryField: { fieldPath: "Name" },
      additionalFields: [{ fieldPath: "Email" }]
    };
  }
  get contactDisplayInfo() {
    return {
      primaryField: "Name",
      additionalFields: ["Email"]
    };
  }

  // ------------------------------------------------------------------ //
  // Form handlers
  // ------------------------------------------------------------------ //

  handleContactChange(event) {
    this.contactId = event.detail.recordId;
  }
  handleDateChange(event) {
    this.callDate = event.detail.value;
  }
  handleOutcomeChange(event) {
    this.outcome = event.detail.value;
  }
  handleNotesChange(event) {
    this.notes = event.detail.value;
  }

  handleReset() {
    this.contactId = null;
    this.callDate = new Date().toISOString().slice(0, 10);
    this.outcome = "";
    this.notes = "";
    const picker = this.template.querySelector("lightning-record-picker");
    if (picker) picker.value = null;
  }

  async handleSubmit() {
    if (!this.runClientValidation()) return;
    this.isSaving = true;
    try {
      await logCallNote({
        payload: {
          opportunityId: this.recordId,
          contactId: this.contactId,
          callDate: this.callDate,
          outcome: this.outcome,
          notes: this.notes
        }
      });
      this.toast("Call note logged", "Saved successfully.", "success");
      this.handleReset();
      await refreshApex(this.wiredNotesResult);
    } catch (err) {
      this.toast("Could not save call note", this.errorMessage(err), "error");
    } finally {
      this.isSaving = false;
    }
  }

  runClientValidation() {
    const inputs = [
      ...this.template.querySelectorAll(
        "lightning-input, lightning-combobox, lightning-textarea"
      )
    ];
    const allValid = inputs.reduce((valid, el) => {
      el.reportValidity();
      return valid && el.checkValidity();
    }, true);
    if (!allValid) {
      this.toast(
        "Check the form",
        "Please correct the highlighted fields.",
        "warning"
      );
    }
    return allValid;
  }

  handleRefresh() {
    this.isLoadingRecent = true;
    refreshApex(this.wiredNotesResult).finally(() => {
      this.isLoadingRecent = false;
    });
  }

  // ------------------------------------------------------------------ //
  // Inline edit
  // ------------------------------------------------------------------ //

  handleEditStart(event) {
    const id = event.currentTarget.dataset.id;
    this.recentNotes = this.recentNotes.map((n) =>
      n.Id === id
        ? {
            ...n,
            editing: true,
            draftNotes: n.Description,
            draftOutcome: n.Call_Outcome__c,
            draftDate: n.ActivityDate
          }
        : { ...n, editing: false }
    );
  }

  handleEditCancel(event) {
    const id = event.currentTarget.dataset.id;
    this.recentNotes = this.recentNotes.map((n) =>
      n.Id === id ? { ...n, editing: false } : n
    );
  }

  handleEditNotesChange(event) {
    const id = event.currentTarget.dataset.id;
    const v = event.detail.value;
    this.recentNotes = this.recentNotes.map((n) =>
      n.Id === id ? { ...n, draftNotes: v } : n
    );
  }

  handleEditOutcomeChange(event) {
    const id = event.currentTarget.dataset.id;
    const v = event.detail.value;
    this.recentNotes = this.recentNotes.map((n) =>
      n.Id === id ? { ...n, draftOutcome: v } : n
    );
  }

  handleEditDateChange(event) {
    const id = event.currentTarget.dataset.id;
    const v = event.detail.value;
    this.recentNotes = this.recentNotes.map((n) =>
      n.Id === id ? { ...n, draftDate: v } : n
    );
  }

  async handleEditSave(event) {
    const id = event.currentTarget.dataset.id;
    const row = this.recentNotes.find((n) => n.Id === id);
    if (!row) return;
    if (!row.draftNotes || !row.draftNotes.trim()) {
      this.toast(
        "Notes required",
        "Please enter notes before saving.",
        "warning"
      );
      return;
    }
    try {
      await updateCallNote({
        taskId: id,
        notes: row.draftNotes,
        outcome: row.draftOutcome,
        callDate: row.draftDate
      });
      this.toast("Call note updated", "", "success");
      await refreshApex(this.wiredNotesResult);
    } catch (err) {
      this.toast("Could not update call note", this.errorMessage(err), "error");
    }
  }

  async handleDelete(event) {
    const id = event.currentTarget.dataset.id;
    const confirmed = await LightningConfirm.open({
      message: "Delete this call note? This action cannot be undone.",
      label: "Confirm delete",
      theme: "warning"
    });
    if (!confirmed) return;
    try {
      await deleteCallNote({ taskId: id });
      this.toast("Call note deleted", "", "success");
      await refreshApex(this.wiredNotesResult);
    } catch (err) {
      this.toast("Could not delete call note", this.errorMessage(err), "error");
    }
  }

  // ------------------------------------------------------------------ //
  // Helpers
  // ------------------------------------------------------------------ //

  toast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
  }

  errorMessage(err) {
    if (!err) return "Unknown error.";
    if (err.body && err.body.message) return err.body.message;
    if (err.message) return err.message;
    return JSON.stringify(err);
  }
}
