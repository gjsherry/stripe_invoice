module StripeInvoice
  class Charge < ActiveRecord::Base
    attr_accessible :id, :invoice_number, :stripe_id, :json, 
      :owner_id, :date, :amount, :discount, :total, :subtotal, :period_start, 
      :period_end, :currency 
    
    alias_attribute :number, :invoice_number

    serialize :json, JSON
    
    def indifferent_json
     @json ||= json.with_indifferent_access 
    end
    
    def datetime
      Time.at(date).to_datetime
    end
    
    def owner
      @owner ||= Koudoku.owner_class.find(owner_id)
    end
    
    def billing_address
      indifferent_json[:metadata][:billing_address] || owner.try(:billing_address)
    end
    
    def tax_number
      indifferent_json[:metadata][:tax_number] || owner.try(:tax_number)
    end
    
    
    def country
      indifferent_json[:metadata][:country] || owner.try(:country)
    end
    
    def refunds
      indifferent_json[:refunds]
    end

    def total_refund
      refunds.inject(0){ |total,refund| total + refund[:amount]}
    end
    
    # builds the invoice from the stripe CHARGE object
    # OR updates the existing invoice if an invoice for that id exists
    def self.create_from_stripe(stripe_charge)
      
      unless stripe_charge.paid
        return puts "[#{self.class.name}##{__method__.to_s}] ignoring unpaid charge #{stripe_charge.id}"
      end
       
      charge = Charge.find_by_stripe_id(stripe_charge[:id])
      
      # for existing invoices just update and be done
      if charge.present?
        puts "[#{self.class.name}##{__method__.to_s}] updating data for #{stripe_charge.id}"
        charge.update_attribute(:json, stripe_charge)
        return charge 
      end
      
      owner = get_subscription_owner stripe_charge
      unless owner
        puts "[#{self.class.name}##{__method__.to_s}] didn't find owner for #{stripe_charge.id}"
        return nil 
      end
      
      stripe_invoice = Stripe::Invoice.retrieve stripe_charge[:invoice]
      last_charge = Charge.last
      new_charge_number = (last_charge ? (last_charge.id * 7) : 1).to_s.rjust(5, '0')
      
      charge_date = Time.at(stripe_charge[:created]).utc.to_datetime
      
      charge = Charge.create({
        stripe_id: stripe_charge[:id], 
        owner_id: owner.id,
        date: stripe_charge[:created],
        amount: stripe_charge[:amount],
        subtotal: stripe_invoice[:subtotal],
        discount: stripe_invoice[:discount],
        total: stripe_invoice[:total],
        currency: stripe_invoice[:currency],
        period_start: stripe_invoice[:period_start],
        period_end: stripe_invoice[:period_end],
        invoice_number: "#{charge_date.year}-#{new_charge_number}",
        json: stripe_charge
      })
      
      puts "Charge saved: #{charge.id}"
    end
    
    private 
    def self.get_subscription_owner(stripe_charge)
      # ::Subscription is generated by Koudoku, but lives in main_app
      subscription = ::Subscription.find_by_stripe_id(stripe_charge.customer)
      
      # we found them directly, go for it. 
      unless subscription.nil?
        puts "[#{self.class.name}##{__method__.to_s}] found subscription for #{stripe_charge.id} - #{subscription}"
        
        #  for some reason that association may be dead
        # so we only return if there is an actual value. 
        # else we'll try the other method
        return subscription.subscription_owner if subscription.subscription_owner
      end 
      
      # koudoku does have a nasty feature/bug in that it deletes the subscription
      # from the database when it is cancelled. This makes it impossible to 
      # match past charges to customers based solely on the subscription's stripe_id
      # instead we also try to match the email address that was send to stripe 
      # when the account was created
      stripe_customer = Stripe::Customer.retrieve stripe_charge.customer
      if stripe_customer[:deleted]
        puts "[#{self.class.name}##{__method__.to_s}] charge owner was deleted: #{stripe_charge.id}"
        return nil  # yes, that can happen :-(
      end
      
      puts "[#{self.class.name}##{__method__.to_s}] found owner via email for #{stripe_charge.id} - #{stripe_customer.email}"
      Koudoku.owner_class.try(:find_by_email, stripe_customer.email)
      
    end
  end
end
