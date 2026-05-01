import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { NavigationMixin } from 'lightning/navigation';
import { getRecord } from 'lightning/uiRecordApi';

import ACCOUNT_NAME from '@salesforce/schema/Account.Name';

import getAccountActivitySummary
    from '@salesforce/apex/AccountActivityController.getAccountActivitySummary';

const STATUS_PILL = {
    Active:    'slds-badge slds-theme_success',
    'At Risk': 'slds-badge slds-theme_error'
};

export default class AccountActivityTile extends NavigationMixin(LightningElement) {
    @api recordId;

    summary;
    error;
    isLoading = true;
    wiredSummary;          // for refreshApex

    /**
     * Wire the Account record so the tile reactively refreshes when the
     * Account changes (e.g. user edits a related Opportunity from the page
     * and the platform marks the cache as dirty). The field list is minimal
     * — we only need the cache invalidation, not the data.
     */
    @wire(getRecord, { recordId: '$recordId', fields: [ACCOUNT_NAME] })
    wiredAccount() { /* no-op — used for cache reactivity */ }

    @wire(getAccountActivitySummary, { accountId: '$recordId' })
    wired(result) {
        this.wiredSummary = result;
        this.isLoading = false;
        if (result.data) {
            this.summary = {
                ...result.data,
                opportunities: (result.data.opportunities || []).map((o) => ({
                    ...o,
                    pillClass: STATUS_PILL[o.status] || 'slds-badge'
                }))
            };
            this.error = null;
        } else if (result.error) {
            this.error = this.errorMessage(result.error);
            this.summary = null;
        }
    }

    get hasData() {
        return !this.isLoading && !!this.summary;
    }

    get hasOpportunities() {
        return this.summary
            && this.summary.opportunities
            && this.summary.opportunities.length > 0;
    }

    get atRiskClass() {
        if (!this.summary) return 'slds-text-heading_large';
        return this.summary.atRiskCount > 0
            ? 'slds-text-heading_large slds-text-color_error'
            : 'slds-text-heading_large';
    }

    /**
     * Use NavigationMixin so the in-app router handles the navigation
     * (faster, preserves SPA state) instead of a hard reload.
     */
    handleNavigate(event) {
        event.preventDefault();
        const id = event.currentTarget.dataset.id;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: id,
                objectApiName: 'Opportunity',
                actionName: 'view'
            }
        });
    }

    @api
    handleRefresh() {
        this.isLoading = true;
        return refreshApex(this.wiredSummary).finally(() => {
            this.isLoading = false;
        });
    }

    errorMessage(err) {
        if (!err) return 'Unknown error.';
        if (err.body && err.body.message) return err.body.message;
        if (err.message) return err.message;
        return JSON.stringify(err);
    }
}
