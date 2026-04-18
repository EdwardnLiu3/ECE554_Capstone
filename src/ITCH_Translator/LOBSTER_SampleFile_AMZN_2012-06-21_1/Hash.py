import csv

hm = {}
highest_present = 0
highest_line = 0

with open('AMZN_2012-06-21_34200000_57600000_message_1.csv', 'r', newline='') as f:
    reader = csv.reader(f)

    for i, row in enumerate(reader):

        try:
            b = int(float(row[1].strip()))
            c = row[2].strip()
            d = int(float(row[3].strip()))
        except Exception as e:
            print("skip row:", row)
            continue

        if b == 1:
            hm[c] = hm.get(c, 0) + d

        elif b == 3:
            if c in hm:
                del hm[c]

        elif b == 5:
            continue

        else:
            if c in hm:
                hm[c] -= d
                if hm[c] <= 0:
                    del hm[c]

        if hm:
            if(len(hm) > highest_present):
                highest_present = len(hm)
                highest_line = i
            
            

print("Final hashmap:", hm)
print("Highest number of present entries:", highest_present)
print("highest_line of present entries:", highest_line)