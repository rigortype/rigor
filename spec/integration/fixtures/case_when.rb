n = 0
label = case n
        when 0 then :zero
        when 1..9 then :small
        else :large
        end
