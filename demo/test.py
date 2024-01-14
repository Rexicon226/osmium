# Super basic fibonacci using only while loop
# No functions
counter = 0
n = 10

a = 0
b = 1
while counter < n:
    counter += 1
    print(b)

    temp = a
    a = b
    b = temp + b
    
print()
